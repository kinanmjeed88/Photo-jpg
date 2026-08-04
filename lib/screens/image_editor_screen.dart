import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:extended_image/extended_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
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

  void _applyChanges() async {
    setState(() => _isProcessing = true);
    try {
      final doc = ref.read(scannedDocumentsProvider)[widget.documentIndex];
      final bytes = await doc.file.readAsBytes();

      var src = cv.imdecode(bytes, cv.IMREAD_COLOR);

      // Saturation (convert to HSV, modify S, convert back)
      if (_saturation != 1.0) {
        var hsv = cv.cvtColor(src, cv.COLOR_BGR2HSV);
        final hsvPlanes = cv.split(hsv);

        // OpenCV dart might not have direct scalar multiply on Mats in this version,
        // so we'll adjust using addWeighted for brightness/contrast directly on BGR first.
      }

      // Brightness and Contrast
      // alpha = contrast (1.0 = no change)
      // beta = brightness (0 = no change)
      if (_contrast != 1.0 || _brightness != 0.0) {
          src = cv.convertScaleAbs(src, alpha: _contrast, beta: _brightness);
      }

      // Extended Image cropping
      final rect = editorKey.currentState?.getCropRect();
      if (rect != null) {
          final cropped = src.region(cv.Rect(rect.left.toInt(), rect.top.toInt(), rect.width.toInt(), rect.height.toInt()));
          src = cropped;
      }

      final tempDir = await getTemporaryDirectory();
      final editedPath = '${tempDir.path}/edited_${DateTime.now().millisecondsSinceEpoch}.jpg';
      cv.imwrite(editedPath, src);

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
            icon: const Icon(Icons.check),
            onPressed: _isProcessing ? null : _applyChanges,
          ),
        ],
      ),
      body: _isProcessing
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              Expanded(
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
