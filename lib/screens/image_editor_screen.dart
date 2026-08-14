import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:permission_handler/permission_handler.dart';

import '../providers/app_state.dart';
import '../services/temporary_image_store.dart';

Future<Map<String, dynamic>> _runProxyIsolate(Map<String, dynamic> args) {
  return Isolate.run(() => _generateProxy(args));
}

Uint8List _encodeJpeg(cv.Mat image) =>
    Uint8List.fromList(cv.imencode('.jpg', image).$2);

Map<String, dynamic> _generateProxy(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  cv.Mat? source;
  cv.Mat? scaled;
  try {
    source = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (source.isEmpty) return <String, dynamic>{'bytes': bytes, 'scale': 1.0};
    final maxDimension = source.cols > source.rows ? source.cols : source.rows;
    if (maxDimension <= 1080) {
      return <String, dynamic>{'bytes': bytes, 'scale': 1.0};
    }
    final scale = 1080 / maxDimension;
    scaled = cv.resize(source, (0, 0), fx: scale, fy: scale);
    return <String, dynamic>{'bytes': _encodeJpeg(scaled), 'scale': scale};
  } catch (_) {
    return <String, dynamic>{'bytes': bytes, 'scale': 1.0};
  } finally {
    source?.dispose();
    scaled?.dispose();
  }
}

class _CropBounds {
  const _CropBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final int left;
  final int top;
  final int width;
  final int height;

  Map<String, int> toMap() => <String, int>{
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  static _CropBounds? fromProxyRect({
    required Rect? rect,
    required double proxyScale,
    required int sourceWidth,
    required int sourceHeight,
  }) {
    if (rect == null || sourceWidth <= 0 || sourceHeight <= 0) return null;
    final safeScale = proxyScale <= 0 ? 1.0 : proxyScale;
    final left = (rect.left / safeScale)
        .floor()
        .clamp(0, sourceWidth - 1)
        .toInt();
    final top = (rect.top / safeScale)
        .floor()
        .clamp(0, sourceHeight - 1)
        .toInt();
    final right = (rect.right / safeScale)
        .ceil()
        .clamp(left + 1, sourceWidth)
        .toInt();
    final bottom = (rect.bottom / safeScale)
        .ceil()
        .clamp(top + 1, sourceHeight)
        .toInt();
    final width = right - left;
    final height = bottom - top;
    if (width <= 0 || height <= 0) return null;
    return _CropBounds(left: left, top: top, width: width, height: height);
  }
}

cv.Mat _applyAdjustments(
  cv.Mat source, {
  required double contrast,
  required double brightness,
  required double sharpness,
}) {
  var current = source;
  if (contrast != 1 || brightness != 0) {
    final adjusted = cv.convertScaleAbs(
      current,
      alpha: contrast,
      beta: brightness,
    );
    if (!identical(current, source)) current.dispose();
    current = adjusted;
  }
  if (sharpness > 0) {
    final blurred = cv.gaussianBlur(current, (0, 0), sharpness);
    final sharpened = cv.addWeighted(current, 1.5, blurred, -0.5, 0);
    blurred.dispose();
    if (!identical(current, source)) current.dispose();
    current = sharpened;
  }
  return current;
}

Uint8List _processForGallery(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final bounds = args['bounds'] as Map<String, int>?;
  cv.Mat? source;
  cv.Mat? processed;
  cv.Mat? cropped;
  try {
    source = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (source.isEmpty) return bytes;
    processed = _applyAdjustments(
      source,
      contrast: args['contrast'] as double,
      brightness: args['brightness'] as double,
      sharpness: args['sharpness'] as double,
    );
    if (bounds != null) {
      cropped = processed.region(
        cv.Rect(
          bounds['left']!,
          bounds['top']!,
          bounds['width']!,
          bounds['height']!,
        ),
      );
    }
    return _encodeJpeg(cropped ?? processed);
  } catch (_) {
    return bytes;
  } finally {
    if (processed != null && !identical(processed, source)) processed.dispose();
    source?.dispose();
    cropped?.dispose();
  }
}

Map<String, dynamic> _processForPreview(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final version = args['version'] as int;
  cv.Mat? source;
  cv.Mat? processed;
  try {
    source = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (source.isEmpty) {
      return <String, dynamic>{'bytes': bytes, 'version': version};
    }
    processed = _applyAdjustments(
      source,
      contrast: args['contrast'] as double,
      brightness: args['brightness'] as double,
      sharpness: args['sharpness'] as double,
    );
    return <String, dynamic>{
      'bytes': _encodeJpeg(processed),
      'version': version,
    };
  } catch (_) {
    return <String, dynamic>{'bytes': bytes, 'version': version};
  } finally {
    if (processed != null && !identical(processed, source)) processed.dispose();
    source?.dispose();
  }
}

bool _processEditedFile(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final outputPath = args['outputPath'] as String;
  final bounds = args['bounds'] as Map<String, int>?;
  cv.Mat? source;
  cv.Mat? processed;
  cv.Mat? cropped;
  try {
    source = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (source.isEmpty) return false;
    processed = _applyAdjustments(
      source,
      contrast: args['contrast'] as double,
      brightness: args['brightness'] as double,
      sharpness: args['sharpness'] as double,
    );
    if (bounds != null) {
      cropped = processed.region(
        cv.Rect(
          bounds['left']!,
          bounds['top']!,
          bounds['width']!,
          bounds['height']!,
        ),
      );
    }
    return cv.imwrite(outputPath, cropped ?? processed);
  } catch (_) {
    return false;
  } finally {
    if (processed != null && !identical(processed, source)) processed.dispose();
    source?.dispose();
    cropped?.dispose();
  }
}

class ImageEditorScreen extends ConsumerStatefulWidget {
  const ImageEditorScreen({super.key, required this.documentId});

  final String documentId;

  @override
  ConsumerState<ImageEditorScreen> createState() => _ImageEditorScreenState();
}

class _ImageEditorScreenState extends ConsumerState<ImageEditorScreen> {
  final GlobalKey<ExtendedImageEditorState> _editorKey =
      GlobalKey<ExtendedImageEditorState>();
  final ValueNotifier<Uint8List?> _previewBytes = ValueNotifier<Uint8List?>(
    null,
  );

  Timer? _debounce;
  Uint8List? _originalBytes;
  Uint8List? _proxyBytes;
  double _proxyScale = 1;
  double _brightness = 0;
  double _contrast = 1;
  double _sharpness = 0;
  int _previewVersion = 0;
  bool _isLoadingPreview = true;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _loadDocument();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _previewBytes.dispose();
    super.dispose();
  }

  DocumentLocation? get _location => ref
      .read(scannedDocumentsProvider.notifier)
      .findDocument(widget.documentId);

  Future<void> _loadDocument() async {
    final location = _location;
    if (location == null) return;
    try {
      _originalBytes = await location.document.file.readAsBytes();
      final result = await _runProxyIsolate(<String, dynamic>{
        'bytes': _originalBytes!,
      });
      _proxyBytes = result['bytes'] as Uint8List;
      _proxyScale = result['scale'] as double;
      final protectedPaths = ref
          .read(scannedDocumentsProvider)
          .values
          .expand((documents) => documents)
          .map((document) => document.file.path)
          .toSet();
      await TemporaryImageStore.cleanupStale(protectedPaths: protectedPaths);
      await _generatePreview();
    } catch (_) {
      // The editor remains usable even if proxy construction fails. Rendering
      // the original bytes is safer than leaving the user on a blank spinner.
      _proxyBytes ??= _originalBytes;
      if (_proxyBytes != null) _previewBytes.value = _proxyBytes!;
      if (mounted) {
        setState(() => _isLoadingPreview = false);
        _showError('تعذر تحضير معاينة محسّنة؛ عُرضت الصورة الأصلية.');
      }
    }
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _previewVersion++;
    _debounce = Timer(const Duration(milliseconds: 120), _generatePreview);
  }

  Future<void> _generatePreview() async {
    if (_proxyBytes == null) {
      if (mounted) setState(() => _isLoadingPreview = false);
      return;
    }
    final version = _previewVersion;
    if (mounted) setState(() => _isLoadingPreview = true);
    try {
      final result = await Isolate.run(
        () => _processForPreview(<String, dynamic>{
          'bytes': _proxyBytes!,
          'contrast': _contrast,
          'brightness': _brightness,
          'sharpness': _sharpness,
          'version': version,
        }),
      );
      if (!mounted || result['version'] != _previewVersion) return;
      _previewBytes.value = result['bytes'] as Uint8List;
    } catch (_) {
      // Keep editing available if an individual effect cannot be rendered.
      // The original image remains visible and applying changes still works.
      if (mounted && version == _previewVersion) {
        _previewBytes.value = _proxyBytes!;
        _showError('تعذر إنشاء معاينة التعديلات؛ عُرضت الصورة الأصلية.');
      }
    } finally {
      if (mounted && version == _previewVersion) {
        setState(() => _isLoadingPreview = false);
      }
    }
  }

  _CropBounds? _currentBounds(ScannedDocument document) {
    return _CropBounds.fromProxyRect(
      rect: _editorKey.currentState?.getCropRect(),
      proxyScale: _proxyScale,
      sourceWidth: document.originalWidth.round(),
      sourceHeight: document.originalHeight.round(),
    );
  }

  Future<void> _saveToGallery() async {
    final location = _location;
    if (location == null || _originalBytes == null) return;
    setState(() => _isProcessing = true);
    try {
      final storage = await Permission.storage.request();
      final photos = await Permission.photos.request();
      if (!storage.isGranted && !photos.isGranted) {
        throw StateError('لم تمنح صلاحية حفظ الصور.');
      }
      final bytes = await Isolate.run(
        () => _processForGallery(<String, dynamic>{
          'bytes': _originalBytes!,
          'bounds': _currentBounds(location.document)?.toMap(),
          'contrast': _contrast,
          'brightness': _brightness,
          'sharpness': _sharpness,
        }),
      );
      await Gal.putImageBytes(
        bytes,
        name: 'scanned_${DateTime.now().microsecondsSinceEpoch}',
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم الحفظ في المعرض.')));
      }
    } catch (_) {
      if (mounted) _showError('تعذر حفظ الصورة في المعرض.');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _applyChanges() async {
    final location = _location;
    if (location == null || _originalBytes == null) return;
    setState(() => _isProcessing = true);
    File? outputFile;
    try {
      final outputPath = await TemporaryImageStore.createPath('edited_');
      outputFile = File(outputPath);
      final wroteFile = await Isolate.run(
        () => _processEditedFile(<String, dynamic>{
          'bytes': _originalBytes!,
          'outputPath': outputPath,
          'bounds': _currentBounds(location.document)?.toMap(),
          'contrast': _contrast,
          'brightness': _brightness,
          'sharpness': _sharpness,
        }),
      );
      if (!wroteFile ||
          !await outputFile.exists() ||
          await outputFile.length() == 0) {
        throw StateError('تعذر إنشاء ملف التعديل.');
      }
      final dimensions = img.decodeImage(await outputFile.readAsBytes());
      if (dimensions == null) throw StateError('ملف التعديل غير صالح.');
      final width = dimensions.width.toDouble();
      final height = dimensions.height.toDouble();
      if (width <= 0 || height <= 0) {
        throw StateError('ملف التعديل غير صالح.');
      }

      final oldFile = location.document.file;
      ref
          .read(scannedDocumentsProvider.notifier)
          .updateDocument(
            widget.documentId,
            file: outputFile,
            originalWidth: width,
            originalHeight: height,
          );
      final oldFileStillReferenced = ref
          .read(scannedDocumentsProvider)
          .values
          .expand((documents) => documents)
          .any((document) => document.file.path == oldFile.path);
      if (!oldFileStillReferenced) {
        await TemporaryImageStore.deleteIfManaged(oldFile);
      }
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (outputFile != null) {
        await TemporaryImageStore.deleteIfManaged(outputFile);
      }
      if (mounted) {
        _showError('تعذر تطبيق التعديلات. لم تتغير الوثيقة الأصلية.');
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final location = ref
        .watch(scannedDocumentsProvider.notifier)
        .findDocument(widget.documentId);
    if (location == null) {
      return const Scaffold(
        body: Center(child: Text('لم تعد هذه الوثيقة متاحة.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('تعديل الصورة'),
        actions: <Widget>[
          if (_isLoadingPreview)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.save_alt),
            tooltip: 'حفظ في المعرض',
            onPressed: _isProcessing ? null : _saveToGallery,
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'تطبيق التعديلات',
            onPressed: _isProcessing ? null : _applyChanges,
          ),
        ],
      ),
      body: _isProcessing
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                Expanded(
                  child: ValueListenableBuilder<Uint8List?>(
                    valueListenable: _previewBytes,
                    builder: (context, preview, child) {
                      if (preview == null) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      return ExtendedImage.memory(
                        preview,
                        fit: BoxFit.contain,
                        mode: ExtendedImageMode.editor,
                        extendedImageEditorKey: _editorKey,
                        initEditorConfigHandler: (state) => EditorConfig(
                          maxScale: 8,
                          cropRectPadding: const EdgeInsets.all(20),
                          hitTestSize: 24,
                          initCropRectType: InitCropRectType.imageRect,
                        ),
                      );
                    },
                  ),
                ),
                _slider(
                  label: 'السطوع',
                  value: _brightness,
                  min: -100,
                  max: 100,
                  onChanged: (value) {
                    setState(() => _brightness = value);
                    _schedulePreview();
                  },
                ),
                _slider(
                  label: 'التباين',
                  value: _contrast,
                  min: 0.5,
                  max: 2,
                  onChanged: (value) {
                    setState(() => _contrast = value);
                    _schedulePreview();
                  },
                ),
                _slider(
                  label: 'الحدّة',
                  value: _sharpness,
                  min: 0,
                  max: 5,
                  onChanged: (value) {
                    setState(() => _sharpness = value);
                    _schedulePreview();
                  },
                ),
              ],
            ),
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: <Widget>[
          SizedBox(width: 64, child: Text(label)),
          Expanded(
            child: Slider(
              value: value,
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
