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


Future<Uint8List> _runPreviewIsolate(Map<String, dynamic> args) async {
  final Uint8List bytes = args['bytes'];
  final double sharpness = args['sharpness'];

  cv.Mat? src;
  cv.Mat? sharpened;
  try {
    src = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (src.isEmpty) return bytes;

    if (sharpness > 0) {
      final blurred = cv.gaussianBlur(src, (0, 0), sharpness);
      sharpened = cv.addWeighted(src, 1.5, blurred, -0.5, 0);
      blurred.dispose();
      src.dispose();
      src = sharpened;
    }

    // Scale down image slightly for live preview to ensure it's fast (<100ms latency target)
    // Actually, only encode to JPG.
    final (_, encodedBytes) = cv.imencode('.jpg', src);
    return encodedBytes;
  } catch (e) {
    print('OpenCV Preview Isolate failed: $e');
    return bytes;
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
  int _isolateTaskCounter = 0;
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
  }

  void _onSliderChanged() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();

    // We update the local UI sliders immediately without blocking.
    // The ColorFiltered widget already handles brightness/contrast instantly.
    // But for Sharpness, we need OpenCV, so we debounce and generate a preview.

    _debounceTimer = Timer(const Duration(milliseconds: 100), () {
      if (_originalBytes != null) {
        _generateLivePreview();
      }
    });
  }

  Future<void> _generateLivePreview() async {
    if (_originalBytes == null) return;

    final int currentTaskId = ++_isolateTaskCounter;
    setState(() => _isLoadingPreview = true);

    try {
      final args = {
        'bytes': _originalBytes!,
        // We only pass sharpness for the live preview because brightness/contrast
        // is ALREADY handled instantly at 60fps by ColorFiltered widget in the UI!
        // Wait, if we are returning a Uint8List to display, it will be inside ColorFiltered.
        // So we should ONLY apply sharpness in this preview.
        'sharpness': _sharpness,
      };

      // Create a top-level isolate function for just sharpness
      final processedBytes = await compute(_runPreviewIsolate, args);

      // Only update if this is the latest task
      if (currentTaskId == _isolateTaskCounter) {
        _previewImage.value = processedBytes;
        if (mounted) setState(() => _isLoadingPreview = false);
      }
    } catch (e) {
      print('Preview Isolate error: $e');
      if (currentTaskId == _isolateTaskCounter && mounted) {
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
      final rectLeft = rect?.left.toInt();
      final rectTop = rect?.top.toInt();
      final rectWidth = rect?.width.toInt();
      final rectHeight = rect?.height.toInt();

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
      final rectLeft = rect?.left.toInt();
      final rectTop = rect?.top.toInt();
      final rectWidth = rect?.width.toInt();
      final rectHeight = rect?.height.toInt();

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
                child: ColorFiltered(
                  colorFilter: ColorFilter.matrix([
                    _contrast, 0, 0, 0, _brightness,
                    0, _contrast, 0, 0, _brightness,
                    0, 0, _contrast, 0, _brightness,
                    0, 0, 0, 1, 0,
                  ]),
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
                        : ExtendedImage.file(
                            doc.file,
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
                          );
                    }
                  ),
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
