import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';

import '../providers/app_state.dart';
import '../services/temporary_image_store.dart';

Future<Map<String, dynamic>> _runProxyIsolate(Map<String, dynamic> args) {
  return Isolate.run(() => _generateProxy(args));
}

Uint8List _encodeJpeg(img.Image image, {int quality = 90}) {
  final encoded = img.encodeJpg(image, quality: quality);
  if (encoded.isEmpty) throw StateError('تعذر ترميز معاينة JPEG.');
  return Uint8List.fromList(encoded);
}

Map<String, dynamic> _generateProxy(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final source = img.decodeImage(bytes);
  if (source == null) {
    throw StateError('ملف الصورة غير صالح للمعاينة.');
  }
  final maximumDimension = source.width > source.height
      ? source.width
      : source.height;
  if (maximumDimension <= 1080) {
    return <String, dynamic>{'bytes': bytes, 'scale': 1.0};
  }
  final scale = 1080 / maximumDimension;
  final proxy = img.copyResize(
    source,
    width: (source.width * scale).round(),
    height: (source.height * scale).round(),
    interpolation: img.Interpolation.average,
  );
  return <String, dynamic>{'bytes': _encodeJpeg(proxy), 'scale': scale};
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

img.Image _applyAdjustments(
  img.Image source, {
  required double contrast,
  required double brightness,
  required double sharpness,
}) {
  final adjusted = img.Image.from(source);
  if (contrast != 1 || brightness != 0) {
    img.adjustColor(
      adjusted,
      contrast: contrast,
      brightness: 1 + (brightness / 100),
    );
  }
  if (sharpness > 0) _applyUnsharpMask(adjusted, sharpness);
  return adjusted;
}

void _applyUnsharpMask(img.Image image, double sharpness) {
  final amount = (sharpness / 5).clamp(0.0, 1.0).toDouble();
  if (amount == 0) return;
  final blurred = img.gaussianBlur(
    img.Image.from(image),
    radius: (sharpness / 2).round().clamp(1, 3),
  );
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final original = image.getPixel(x, y);
      final softened = blurred.getPixel(x, y);
      num channel(num base, num blur) =>
          (base + ((base - blur) * amount)).clamp(0, 255);
      image.setPixelRgba(
        x,
        y,
        channel(original.r, softened.r),
        channel(original.g, softened.g),
        channel(original.b, softened.b),
        original.a,
      );
    }
  }
}

img.Image _cropIfRequested(img.Image image, Map<String, int>? bounds) {
  if (bounds == null || image.width <= 0 || image.height <= 0) return image;

  final left = (bounds['left'] ?? 0).clamp(0, image.width - 1).toInt();
  final top = (bounds['top'] ?? 0).clamp(0, image.height - 1).toInt();
  final width = (bounds['width'] ?? image.width - left)
      .clamp(1, image.width - left)
      .toInt();
  final height = (bounds['height'] ?? image.height - top)
      .clamp(1, image.height - top)
      .toInt();

  return img.copyCrop(image, x: left, y: top, width: width, height: height);
}

Uint8List _processForGallery(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final source = img.decodeImage(bytes);
  if (source == null) throw StateError('ملف الصورة غير صالح.');
  final processed = _applyAdjustments(
    source,
    contrast: args['contrast'] as double,
    brightness: args['brightness'] as double,
    sharpness: args['sharpness'] as double,
  );
  return _encodeJpeg(
    _cropIfRequested(processed, args['bounds'] as Map<String, int>?),
  );
}

Map<String, dynamic> _processForPreview(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final version = args['version'] as int;
  final source = img.decodeImage(bytes);
  if (source == null) throw StateError('ملف معاينة غير صالح.');

  // Brightness and contrast are rendered synchronously by the Flutter layer so
  // slider changes are visible on the same frame. Only the expensive raster
  // operation is delegated to the isolate.
  final processed = _applyAdjustments(
    source,
    contrast: 1,
    brightness: 0,
    sharpness: args['sharpness'] as double,
  );
  return <String, dynamic>{'bytes': _encodeJpeg(processed), 'version': version};
}

Uint8List _processEditedBytes(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final source = img.decodeImage(bytes);
  if (source == null) throw StateError('ملف الصورة غير صالح.');
  final processed = _applyAdjustments(
    source,
    contrast: args['contrast'] as double,
    brightness: args['brightness'] as double,
    sharpness: args['sharpness'] as double,
  );
  final output = _cropIfRequested(
    processed,
    args['bounds'] as Map<String, int>?,
  );
  return _encodeJpeg(output);
}

class ImageEditorScreen extends ConsumerStatefulWidget {
  const ImageEditorScreen({
    super.key,
    required this.documentId,
    this.useOriginalSource = false,
  });

  final String documentId;
  final bool useOriginalSource;

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
  int _sourceWidth = 0;
  int _sourceHeight = 0;
  double _proxyScale = 1;
  double _brightness = 0;
  double _contrast = 1;
  double _sharpness = 0;
  int _previewVersion = 0;
  bool _isPreviewTaskRunning = false;
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
      var sourceFile = location.document.file;
      if (widget.useOriginalSource &&
          location.document.originalImagePath != null) {
        final originalFile = File(location.document.originalImagePath!);
        if (await originalFile.exists()) sourceFile = originalFile;
      }
      _originalBytes = await sourceFile.readAsBytes();
      final decodedSource = img.decodeImage(_originalBytes!);
      if (decodedSource == null) {
        throw StateError('ملف الصورة غير صالح للتحرير.');
      }
      _sourceWidth = decodedSource.width;
      _sourceHeight = decodedSource.height;
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
      // A valid source still remains editable even if its downscaled proxy could
      // not be generated. The UI deliberately keeps this fallback silent.
      _proxyBytes ??= _originalBytes;
      if (_proxyBytes != null) _previewBytes.value = _proxyBytes!;
      if (mounted) setState(() => _isLoadingPreview = false);
    }
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _previewVersion++;
    _debounce = Timer(const Duration(milliseconds: 40), _generatePreview);
  }

  Future<void> _generatePreview() async {
    if (_proxyBytes == null) {
      if (mounted) setState(() => _isLoadingPreview = false);
      return;
    }
    // Slider changes may be more frequent than image processing. Run at most
    // one isolate at a time and immediately process only the newest values.
    if (_isPreviewTaskRunning) return;
    _isPreviewTaskRunning = true;
    try {
      var processedVersion = -1;
      do {
        final version = _previewVersion;
        processedVersion = version;
        final bytes = _proxyBytes!;
        final contrast = _contrast;
        final brightness = _brightness;
        final sharpness = _sharpness;
        final result = await Isolate.run(
          () => _processForPreview(<String, dynamic>{
            'bytes': bytes,
            'contrast': contrast,
            'brightness': brightness,
            'sharpness': sharpness,
            'version': version,
          }),
        );
        if (!mounted) return;
        if (result['version'] == _previewVersion) {
          _previewBytes.value = result['bytes'] as Uint8List;
        }
      } while (mounted && processedVersion != _previewVersion);
    } catch (_) {
      // Never interrupt an editing gesture with an error banner. The previous
      // valid preview remains on screen; the next slider change retries.
      if (mounted && _previewBytes.value == null) {
        _previewBytes.value = _proxyBytes;
      }
    } finally {
      _isPreviewTaskRunning = false;
      if (mounted) setState(() => _isLoadingPreview = false);
    }
  }

  _CropBounds? _currentBounds() {
    return _CropBounds.fromProxyRect(
      rect: _editorKey.currentState?.getCropRect(),
      proxyScale: _proxyScale,
      sourceWidth: _sourceWidth,
      sourceHeight: _sourceHeight,
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
          'bounds': _currentBounds()?.toMap(),
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
      final encoded = await Isolate.run(
        () => _processEditedBytes(<String, dynamic>{
          'bytes': _originalBytes!,
          'bounds': _currentBounds()?.toMap(),
          'contrast': _contrast,
          'brightness': _brightness,
          'sharpness': _sharpness,
        }),
      );
      if (encoded.isEmpty) throw StateError('تعذر إنشاء ملف التعديل.');
      await outputFile.writeAsBytes(encoded, flush: true);
      if (!await outputFile.exists() || await outputFile.length() == 0) {
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
        title: Text(
          widget.useOriginalSource ? 'تعديل الصورة الأصلية' : 'تعديل الصورة',
        ),
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
                      return _buildPreview(preview);
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
                  },
                ),
                _slider(
                  label: 'التباين',
                  value: _contrast,
                  min: 0.5,
                  max: 2,
                  onChanged: (value) {
                    setState(() => _contrast = value);
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

  List<double> _previewColorMatrix() {
    final brightnessScale = 1 + (_brightness / 100);
    final effectiveContrast = _contrast * brightnessScale;
    final intercept = 127.5 * (1 - _contrast);
    return <double>[
      effectiveContrast,
      0,
      0,
      0,
      intercept,
      0,
      effectiveContrast,
      0,
      0,
      intercept,
      0,
      0,
      effectiveContrast,
      0,
      intercept,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  Widget _buildPreview(Uint8List preview) {
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(_previewColorMatrix()),
      child: ExtendedImage.memory(
        preview,
        fit: BoxFit.contain,
        mode: ExtendedImageMode.editor,
        extendedImageEditorKey: _editorKey,
        initEditorConfigHandler: (state) => EditorConfig(
          maxScale: 8,
          cropRectPadding: const EdgeInsets.all(20),
          hitTestSize: 32,
          initCropRectType: InitCropRectType.imageRect,
        ),
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
