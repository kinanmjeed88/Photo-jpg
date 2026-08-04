import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:extended_image/extended_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:gal/gal.dart';
import 'package:permission_handler/permission_handler.dart';
import '../providers/app_state.dart';

class ImageEditorScreen extends ConsumerStatefulWidget {
  final int documentIndex;

  const ImageEditorScreen({super.key, required this.documentIndex});

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
      final doc = ref.read(scannedDocumentsProvider)[widget.documentIndex];
      final bytes = await doc.file.readAsBytes();

      final rect = editorKey.currentState?.getCropRect();
      final rectLeft = rect?.left.toInt();
      final rectTop = rect?.top.toInt();
      final rectWidth = rect?.width.toInt();
      final rectHeight = rect?.height.toInt();

      final contrast = _contrast;
      final brightness = _brightness;

      final processedBytes = await Isolate.run(() {
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
      });

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
      final doc = ref.read(scannedDocumentsProvider)[widget.documentIndex];
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
      final editedPath = await Isolate.run(() {
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
      });

      final newDoc = ScannedDocument(file: File(editedPath), type: doc.type);
      ref.read(scannedDocumentsProvider.notifier).updateDocumentAt(widget.documentIndex, newDoc);

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
    final docs = ref.watch(scannedDocumentsProvider);
    if (widget.documentIndex >= docs.length) return const Scaffold();

    final doc = docs[widget.documentIndex];

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
