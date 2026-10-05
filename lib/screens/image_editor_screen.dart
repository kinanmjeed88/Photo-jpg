import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../providers/app_state.dart';
import '../services/gallery_service.dart';
import '../services/image_pipeline.dart';
import '../services/temporary_image_store.dart';

/// Builds the editing proxy and reports the source dimensions in one pass.
///
/// Runs inside an isolate: it only receives and returns sendable values, so it
/// never touches the widget tree or a `GlobalKey`.
Map<String, Object> _generateProxyInIsolate(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  // Reports the upright dimensions, so the crop rectangle taken from the editor
  // (which is expressed in the pixels the editor actually displays) maps onto
  // the same pixel grid the export crops from.
  final oriented = createOrientedProxy(bytes);
  return <String, Object>{
    'bytes': oriented.proxy.bytes,
    'scale': oriented.proxy.scale,
    'width': oriented.width,
    'height': oriented.height,
  };
}

/// Applies the unsharp mask to the proxy for the live preview.
///
/// The tone curve is rendered by the GPU through [ImageAdjustments.colorMatrix],
/// which is the same gain/offset pair used by the export path, so only the
/// sharpen pass has to run here.
Uint8List _renderPreview(Map<String, dynamic> args) {
  final source = img.decodeImage(args['bytes'] as Uint8List);
  if (source == null) {
    throw StateError('ملف معاينة غير صالح.');
  }
  final adjustments = ImageAdjustments(sharpness: args['sharpness'] as double);
  if (adjustments.normalized.sharpness > 0) {
    sharpenInPlace(source, adjustments);
  }
  return encodeJpeg(source);
}

/// Renders the final image at full resolution: sharpness, tone and crop.
Map<String, Object> _renderExport(Map<String, dynamic> args) {
  // Both the proxy and the editor's crop rectangle live in upright pixel space,
  // so the orientation tag has to be baked before those coordinates are used.
  final source = decodeOriented(args['bytes'] as Uint8List);
  final adjustments = ImageAdjustments(
    contrast: args['contrast'] as double,
    brightness: args['brightness'] as double,
    sharpness: args['sharpness'] as double,
  );
  final processed = applyAdjustments(source, adjustments);
  final bounds = CropBounds.fromMap(args['bounds']);
  final output = bounds == null ? processed : bounds.crop(processed);
  return <String, Object>{
    'bytes': encodeJpeg(output),
    'width': output.width,
    'height': output.height,
  };
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
  Uint8List? _sourceBytes;
  Uint8List? _proxyBytes;
  int _sourceWidth = 0;
  int _sourceHeight = 0;
  double _proxyScale = 1;
  ImageAdjustments _adjustments = const ImageAdjustments();
  int _previewVersion = 0;
  bool _isPreviewTaskRunning = false;
  bool _isLoadingPreview = true;
  bool _isProcessing = false;
  String? _loadError;

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
      if (!await sourceFile.exists()) {
        throw StateError('الصورة الأصلية غير متوفرة.');
      }
      final bytes = await sourceFile.readAsBytes();
      final proxy = await Isolate.run(
        () => _generateProxyInIsolate(<String, dynamic>{'bytes': bytes}),
      );
      if (!mounted) return;
      _sourceBytes = bytes;
      _proxyBytes = proxy['bytes']! as Uint8List;
      _proxyScale = (proxy['scale']! as num).toDouble();
      _sourceWidth = (proxy['width']! as num).toInt();
      _sourceHeight = (proxy['height']! as num).toInt();
      await _generatePreview();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoadingPreview = false;
        _loadError = error is StateError
            ? error.message
            : 'تعذر تحميل الصورة للتحرير.';
      });
    }
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _previewVersion++;
    _debounce = Timer(const Duration(milliseconds: 40), _generatePreview);
  }

  Future<void> _generatePreview() async {
    final proxyBytes = _proxyBytes;
    if (proxyBytes == null) {
      if (mounted) setState(() => _isLoadingPreview = false);
      return;
    }
    if (_adjustments.normalized.sharpness <= 0) {
      // Nothing to sharpen: the proxy itself is the preview, so no isolate is
      // started and the original quality is shown untouched.
      _previewBytes.value = proxyBytes;
      if (mounted) setState(() => _isLoadingPreview = false);
      return;
    }
    // Slider changes can be more frequent than image processing. Run at most
    // one isolate at a time and always converge on the newest values.
    if (_isPreviewTaskRunning) return;
    _isPreviewTaskRunning = true;
    try {
      var processedVersion = -1;
      do {
        final version = _previewVersion;
        processedVersion = version;
        final bytes = proxyBytes;
        final sharpness = _adjustments.sharpness;
        final result = await Isolate.run(
          () => _renderPreview(<String, dynamic>{
            'bytes': bytes,
            'sharpness': sharpness,
          }),
        );
        if (!mounted) return;
        if (version == _previewVersion) {
          _previewBytes.value = result;
        }
      } while (mounted && processedVersion != _previewVersion);
    } catch (_) {
      // Never interrupt an editing gesture with an error banner. The previous
      // valid preview remains on screen; the next slider change retries.
      if (mounted && _previewBytes.value == null) {
        _previewBytes.value = proxyBytes;
      }
    } finally {
      _isPreviewTaskRunning = false;
      if (mounted) setState(() => _isLoadingPreview = false);
    }
  }

  /// Reads the crop rectangle from the editor state.
  ///
  /// Must run on the UI isolate: `getCropRect()` walks the live render tree and
  /// returns proxy-pixel coordinates, which are then mapped to the
  /// full-resolution source by [CropBounds.fromProxyRect].
  CropBounds? _currentBounds() {
    return CropBounds.fromProxyRect(
      rect: _editorKey.currentState?.getCropRect(),
      proxyScale: _proxyScale,
      sourceWidth: _sourceWidth,
      sourceHeight: _sourceHeight,
    );
  }

  Future<void> _saveToGallery() async {
    final location = _location;
    final sourceBytes = _sourceBytes;
    if (location == null || sourceBytes == null) return;
    final bounds = _currentBounds();
    final adjustments = _adjustments;
    setState(() => _isProcessing = true);
    try {
      // The export is rendered first: permission prompts are only shown once the
      // user has something to save, and the render result is never discarded
      // because a dialog was dismissed.
      final result = await Isolate.run(
        () => _renderExport(<String, dynamic>{
          'bytes': sourceBytes,
          'bounds': bounds?.toMap(),
          'contrast': adjustments.contrast,
          'brightness': adjustments.brightness,
          'sharpness': adjustments.sharpness,
        }),
      );
      await GalleryService.saveBytes(
        result['bytes']! as Uint8List,
        name: 'scanned_${DateTime.now().microsecondsSinceEpoch}',
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تم الحفظ في المعرض.')));
      }
    } catch (error) {
      if (mounted) _showError(GalleryService.describe(error));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _applyChanges() async {
    final location = _location;
    final sourceBytes = _sourceBytes;
    if (location == null || sourceBytes == null) return;
    final bounds = _currentBounds();
    final adjustments = _adjustments;
    setState(() => _isProcessing = true);
    File? outputFile;
    try {
      final outputPath = await TemporaryImageStore.createPath('edited_');
      outputFile = File(outputPath);
      final result = await Isolate.run(
        () => _renderExport(<String, dynamic>{
          'bytes': sourceBytes,
          'bounds': bounds?.toMap(),
          'contrast': adjustments.contrast,
          'brightness': adjustments.brightness,
          'sharpness': adjustments.sharpness,
        }),
      );
      final encoded = result['bytes']! as Uint8List;
      final width = (result['width']! as num).toDouble();
      final height = (result['height']! as num).toDouble();
      if (encoded.isEmpty || width <= 0 || height <= 0) {
        throw StateError('تعذر إنشاء ملف التعديل.');
      }
      await outputFile.writeAsBytes(encoded, flush: true);
      if (!await outputFile.exists() || await outputFile.length() == 0) {
        throw StateError('تعذر إنشاء ملف التعديل.');
      }

      final oldFile = location.document.file;
      // The crop changes the pixel dimensions, so the layout box is re-fitted
      // to the new aspect ratio inside the same state transaction.
      ref
          .read(scannedDocumentsProvider.notifier)
          .replaceDocumentImage(
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
    final canApply = _sourceBytes != null && !_isProcessing;
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
            onPressed: canApply ? _saveToGallery : null,
          ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'تطبيق التعديلات',
            onPressed: canApply ? _applyChanges : null,
          ),
        ],
      ),
      body: _isProcessing
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? _buildLoadError(_loadError!)
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
                  value: _adjustments.brightness,
                  min: ImageAdjustments.minimumBrightness,
                  max: ImageAdjustments.maximumBrightness,
                  onChanged: (value) {
                    setState(() {
                      _adjustments = _adjustments.copyWith(brightness: value);
                    });
                  },
                ),
                _slider(
                  label: 'التباين',
                  value: _adjustments.contrast,
                  min: ImageAdjustments.minimumContrast,
                  max: ImageAdjustments.maximumContrast,
                  onChanged: (value) {
                    setState(() {
                      _adjustments = _adjustments.copyWith(contrast: value);
                    });
                  },
                ),
                _slider(
                  label: 'الحدّة',
                  value: _adjustments.sharpness,
                  min: ImageAdjustments.minimumSharpness,
                  max: ImageAdjustments.maximumSharpness,
                  onChanged: (value) {
                    setState(() {
                      _adjustments = _adjustments.copyWith(sharpness: value);
                    });
                    _schedulePreview();
                  },
                ),
              ],
            ),
    );
  }

  Widget _buildLoadError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.broken_image_outlined, size: 56),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview(Uint8List preview) {
    // The tone curve is rendered by the GPU through the exact same gain/offset
    // pair the export path uses, so the preview faithfully represents the file
    // that will be written.
    return ColorFiltered(
      colorFilter: ColorFilter.matrix(_adjustments.colorMatrix),
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
          // Fixed handle colours keep the crop layer readable even when the
          // tone curve pushes the underlying image to black or white.
          cornerColor: Colors.white,
          lineColor: Colors.white70,
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
