import 'dart:io';
import 'dart:isolate';
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

  cv.Mat? src;
  cv.Mat? scaled;
  cv.Mat? cropped;
  try {
    src = cv.imdecode(bytes, cv.IMREAD_COLOR);

    if (contrast != 1.0 || brightness != 0.0) {
      scaled = cv.convertScaleAbs(src, alpha: contrast, beta: brightness);
      src.dispose();
      src = scaled;
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

String _processEditedImage(Map<String, dynamic> args) {
  final Uint8List bytes = args['bytes'];
  final int? rectLeft = args['rectLeft'];
  final int? rectTop = args['rectTop'];
  final int? rectWidth = args['rectWidth'];
  final int? rectHeight = args['rectHeight'];
  final double contrast = args['contrast'];
  final double brightness = args['brightness'];
  final String tempPath = args['tempPath'];
  final String docPath = args['docPath'];

  cv.Mat? src;
  cv.Mat? scaled;
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
  double _saturation = 1;
  bool _isProcessing = false;

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

      final String docPath = doc.file.path;

      final args = {
        'bytes': bytes,
        'rectLeft': rectLeft,
        'rectTop': rectTop,
        'rectWidth': rectWidth,
        'rectHeight': rectHeight,
        'contrast': contrast,
        'brightness': brightness,
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
                  child: ExtendedImage.file(
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
                            onChanged: (v) => setState(() => _brightness = v),
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
                            onChanged: (v) => setState(() => _contrast = v),
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
