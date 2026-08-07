import 'dart:io';
import 'dart:isolate';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:extended_image/extended_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'dart:typed_data';
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';
import '../providers/app_state.dart';


Future<Map<String, dynamic>> _runProxyIsolate(Map<String, dynamic> args) {
  return Isolate.run(() => _generateProxy(args));
}

Map<String, dynamic> _generateProxy(Map<String, dynamic> args) {
  final Uint8List bytes = args['bytes'];
  cv.Mat? src;
  cv.Mat? scaled;
  try {
    src = cv.imdecode(bytes, cv.IMREAD_COLOR);
    double scale = 1.0;
    int maxDim = src.cols > src.rows ? src.cols : src.rows;
    if (maxDim > 1080) {
      scale = 1080.0 / maxDim;
      scaled = cv.resize(src, (0, 0), fx: scale, fy: scale);
      final (_, encodedBytes) = cv.imencode('.jpg', scaled);
      return {'bytes': encodedBytes, 'scale': scale};
    }
    return {'bytes': bytes, 'scale': 1.0};
  } catch (e) {
    print('Proxy Isolate failed: $e');
    return {'bytes': bytes, 'scale': 1.0};
  } finally {
    src?.dispose();
    scaled?.dispose();
  }
}

Future<Uint8List> _runGalleryIsolate(Map<String, dynamic> args) {
  return Isolate.run(() => _processGalleryImage(args));
}

Future<String> _runEditedIsolate(Map<String, dynamic> args) {
  return Isolate.run(() => _processEditedImage(args));
}

Uint8List _processGalleryImage(Map<String, dynamic> args) {
  final Uint8List bytes = args['bytes'];
  final int? rectLeft = args['rectLeft'];
  final int? rectTop = args['rectTop'];
  final int? rectWidth = args['rectWidth'];
  final int? rectHeight = args['rectHeight'];
  final double contrast = args['contrast'];
  final double brightness = args['brightness'];
  final double sharpness = args['sharpness'];

  cv.Mat? src;
  cv.Mat? scaled;
  cv.Mat? sharpened;
  cv.Mat? cropped;
  try {
    src = cv.imdecode(bytes, cv.IMREAD_COLOR);

    if (contrast != 1.0 || brightness != 0.0) {
      scaled = cv.convertScaleAbs(src, alpha: contrast, beta: brightness);
      src.dispose();
      src = scaled;
    }

    if (sharpness > 0) {
      final blurred = cv.gaussianBlur(src, (0, 0), sharpness);
      sharpened = cv.addWeighted(src, 1.5, blurred, -0.5, 0);
      blurred.dispose();
      src.dispose();
      src = sharpened;
    }

    if (rectLeft != null && rectTop != null && rectWidth != null && rectHeight != null) {
      cropped = src.region(cv.Rect(rectLeft, rectTop, rectWidth, rectHeight));
      final (_, encodedBytes) = cv.imencode('.jpg', cropped);
      return encodedBytes;
    } else {
      final (_, encodedBytes) = cv.imencode('.jpg', src);
      return encodedBytes;
    }
  } catch (e) {
    print('Gallery save OpenCV failed: $e');
    return bytes;
  } finally {
    src?.dispose();
    cropped?.dispose();
  }
}


Future<Map<String, dynamic>> _runPreviewIsolate(Map<String, dynamic> args) async {
  final Uint8List bytes = args['bytes'];
  final double contrast = args['contrast'];
  final double brightness = args['brightness'];
  final double sharpness = args['sharpness'];
  final int version = args['version'];

  cv.Mat? src;
  cv.Mat? scaled;
  cv.Mat? sharpened;
  try {
    src = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (src.isEmpty) return {'bytes': bytes, 'version': version};

    if (contrast != 1.0 || brightness != 0.0) {
      scaled = cv.convertScaleAbs(src, alpha: contrast, beta: brightness);
      src.dispose();
      src = scaled;
    }

    if (sharpness > 0) {
      final blurred = cv.gaussianBlur(src, (0, 0), sharpness);
      sharpened = cv.addWeighted(src, 1.5, blurred, -0.5, 0);
      blurred.dispose();
      src.dispose();
      src = sharpened;
    }

    final (_, encodedBytes) = cv.imencode('.jpg', src);
    return {'bytes': encodedBytes, 'version': version};
  } catch (e) {
    print('OpenCV Preview Isolate failed: $e');
    return {'bytes': bytes, 'version': version};
  } finally {
    src?.dispose();
  }
}

String _processEditedImage(Map<String, dynamic> args) {

  final Uint8List bytes = args['bytes'];
  final int? rectLeft = args['rectLeft'];
  final int? rectTop = args['rectTop'];
  final int? rectWidth = args['rectWidth'];
  final int? rectHeight = args['rectHeight'];
  final double contrast = args['contrast'];
  final double brightness = args['brightness'];
  final double sharpness = args['sharpness'];
  final String tempPath = args['tempPath'];
  final String docPath = args['docPath'];

  cv.Mat? src;
  cv.Mat? scaled;
  cv.Mat? sharpened;
  cv.Mat? cropped;
  try {
    src = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (src.isEmpty) {
      return docPath;
    }

    if (contrast != 1.0 || brightness != 0.0) {
      scaled = cv.convertScaleAbs(src, alpha: contrast, beta: brightness);
      src.dispose();
      src = scaled;
    }

    if (sharpness > 0) {
      final blurred = cv.gaussianBlur(src, (0, 0), sharpness);
      sharpened = cv.addWeighted(src, 1.5, blurred, -0.5, 0);
      blurred.dispose();
      src.dispose();
      src = sharpened;
    }

    final outPath = '$tempPath/edited_${DateTime.now().millisecondsSinceEpoch}.jpg';
    if (rectLeft != null && rectTop != null && rectWidth != null && rectHeight != null) {
      cropped = src.region(cv.Rect(rectLeft, rectTop, rectWidth, rectHeight));
      cv.imwrite(outPath, cropped);
    } else {
      cv.imwrite(outPath, src);
    }
    return outPath;
  } catch (e) {
    print('OpenCV Isolate failed: $e');
    return docPath;
  } finally {
    src?.dispose();
    cropped?.dispose();
  }
}

class ImageEditorScreen extends ConsumerStatefulWidget {
  final int pageIndex;
  final int documentIndex;

  const ImageEditorScreen({super.key, required this.pageIndex, required this.documentIndex});

  @override
  ConsumerState<ImageEditorScreen> createState() => _ImageEditorScreenState();
}


class _ImageEditorScreenState extends ConsumerState<ImageEditorScreen> {
  final GlobalKey<ExtendedImageEditorState> editorKey = GlobalKey<ExtendedImageEditorState>();

  double _brightness = 0;
  double _contrast = 1;
  double _sharpness = 0;
  bool _isProcessing = false;

  Timer? _debounceTimer;
  ValueNotifier<Uint8List?> _previewImage = ValueNotifier<Uint8List?>(null);
  Uint8List? _originalBytes;

  Uint8List? _proxyBytes;
  double _proxyScale = 1.0;
  int _previewVersion = 0;

  bool _isLoadingPreview = false;

  @override
  void initState() {
    super.initState();
    _loadOriginalBytes();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _previewImage.dispose();
    super.dispose();
  }

  Future<void> _loadOriginalBytes() async {
    final pageDocs = ref.read(scannedDocumentsProvider)[widget.pageIndex];
    if (pageDocs == null) return;
    final doc = pageDocs[widget.documentIndex];
    _originalBytes = await doc.file.readAsBytes();

    setState(() => _isLoadingPreview = true);
    final proxyResult = await _runProxyIsolate({'bytes': _originalBytes!});
    _proxyBytes = proxyResult['bytes'];
    _proxyScale = proxyResult['scale'];

    _generateLivePreview();
  }

  void _onSliderChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    _previewVersion++;

    _debounceTimer = Timer(const Duration(milliseconds: 100), () {
      if (_proxyBytes != null) {
        _generateLivePreview();
      }
    });
  }

  Future<void> _generateLivePreview() async {
    if (_proxyBytes == null) return;

    final int currentVersion = _previewVersion;
    setState(() => _isLoadingPreview = true);

    try {
      final args = {
        'bytes': _proxyBytes!,
        'contrast': _contrast,
        'brightness': _brightness,
        'sharpness': _sharpness,
        'version': currentVersion,
      };

      final result = await compute(_runPreviewIsolate, args);

      final int resultVersion = result['version'];
      if (resultVersion < _previewVersion) {
        // Discard stale result
        return;
      }

      _previewImage.value = result['bytes'];
      if (mounted) setState(() => _isLoadingPreview = false);
    } catch (e) {
      print('Preview Isolate error: $e');
      if (currentVersion == _previewVersion && mounted) {
        setState(() => _isLoadingPreview = false);
      }
    }
  }


  Future<void> _saveToGallery() async {
    final status = await Permission.storage.request();
    if (!status.isGranted && !await Permission.photos.request().isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الرجاء منح صلاحية الوصول إلى المعرض')),
        );
      }
      return;
    }

    setState(() => _isProcessing = true);
    try {
      final pageDocs = ref.read(scannedDocumentsProvider)[widget.pageIndex];
      if (pageDocs == null) return;
      final doc = pageDocs[widget.documentIndex];
      final bytes = await doc.file.readAsBytes();

      final rect = editorKey.currentState?.getCropRect();
      final rectLeft = rect != null ? (rect.left / _proxyScale).toInt() : null;
      final rectTop = rect != null ? (rect.top / _proxyScale).toInt() : null;
      final rectWidth = rect != null ? (rect.width / _proxyScale).toInt() : null;
      final rectHeight = rect != null ? (rect.height / _proxyScale).toInt() : null;

      final args = {
        'bytes': bytes,
        'rectLeft': rectLeft,
        'rectTop': rectTop,
        'rectWidth': rectWidth,
        'rectHeight': rectHeight,
        'contrast': _contrast,
        'brightness': _brightness,
        'sharpness': _sharpness,
      };

      final processedBytes = await _runGalleryIsolate(args);

      await Gal.putImageBytes(
        processedBytes,
        name: "scanned_${DateTime.now().millisecondsSinceEpoch}"
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم الحفظ في المعرض')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('حدث خطأ أثناء الحفظ: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _applyChanges() async {
    setState(() => _isProcessing = true);
    try {
      final pageDocs = ref.read(scannedDocumentsProvider)[widget.pageIndex];
      if (pageDocs == null) return;
      final doc = pageDocs[widget.documentIndex];
      final bytes = await doc.file.readAsBytes();

      final rect = editorKey.currentState?.getCropRect();
      final rectLeft = rect != null ? (rect.left / _proxyScale).toInt() : null;
      final rectTop = rect != null ? (rect.top / _proxyScale).toInt() : null;
      final rectWidth = rect != null ? (rect.width / _proxyScale).toInt() : null;
      final rectHeight = rect != null ? (rect.height / _proxyScale).toInt() : null;

      final tempDir = await getTemporaryDirectory();
      final tempPath = tempDir.path;
      final contrast = _contrast;
      final brightness = _brightness;
      final sharpness = _sharpness;

      final String docPath = doc.file.path;

      final args = {
        'bytes': bytes,
        'rectLeft': rectLeft,
        'rectTop': rectTop,
        'rectWidth': rectWidth,
        'rectHeight': rectHeight,
        'contrast': contrast,
        'brightness': brightness,
        'sharpness': sharpness,
        'tempPath': tempPath,
        'docPath': docPath,
      };

      final editedPath = await _runEditedIsolate(args);

      final newDoc = doc.copyWith(file: File(editedPath));
      ref.read(scannedDocumentsProvider.notifier).updateDocumentAt(widget.pageIndex, widget.documentIndex, newDoc);

      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      print('Editor failed: $e');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(scannedDocumentsProvider);
    if (!pages.containsKey(widget.pageIndex)) return const Scaffold();

    final pageDocs = pages[widget.pageIndex]!;
    if (widget.documentIndex >= pageDocs.length) return const Scaffold();

    final doc = pageDocs[widget.documentIndex];

    return Scaffold(
      appBar: AppBar(
        title: const Text('تعديل الصورة'),
        actions: [
          if (_isLoadingPreview)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16.0),
                child: SizedBox(
                  width: 20, height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                ),
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
            children: [
              Expanded(
                child: ValueListenableBuilder<Uint8List?>(
                  valueListenable: _previewImage,
                  builder: (context, previewBytes, child) {
                    return previewBytes != null
                      ? ExtendedImage.memory(
                          previewBytes,
                          fit: BoxFit.contain,
                          mode: ExtendedImageMode.editor,
                          extendedImageEditorKey: editorKey,
                          initEditorConfigHandler: (ExtendedImageState? state) {
                            return EditorConfig(
                              maxScale: 8.0,
                              cropRectPadding: const EdgeInsets.all(20.0),
                              hitTestSize: 20.0,
                            );
                          },
                        )
                      : const Center(child: CircularProgressIndicator());
                  }
                ),
              ),
              Container(
                color: const Color(0xFF1E293B),
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.brightness_6, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: _brightness,
                            min: -100,
                            max: 100,
                            onChanged: (v) {
                              setState(() => _brightness = v);
                              _onSliderChanged();
                            }
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Icon(Icons.contrast, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: _contrast,
                            min: 0.5,
                            max: 3.0,
                            onChanged: (v) {
                              setState(() => _contrast = v);
                              _onSliderChanged();
                            }
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Icon(Icons.lens_blur, size: 20),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Slider(
                            value: _sharpness,
                            min: 0.0,
                            max: 10.0,
                            onChanged: (v) {
                              setState(() => _sharpness = v);
                              _onSliderChanged();
                            }
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
    );
  }

}
