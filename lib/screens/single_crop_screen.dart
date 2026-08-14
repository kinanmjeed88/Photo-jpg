import 'dart:io';

import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:image_editor/image_editor.dart';

import '../services/temporary_image_store.dart';

class SingleCropScreen extends StatefulWidget {
  const SingleCropScreen({super.key, required this.imageFile});

  final File imageFile;

  @override
  State<SingleCropScreen> createState() => _SingleCropScreenState();
}

class _SingleCropScreenState extends State<SingleCropScreen> {
  final GlobalKey<ExtendedImageEditorState> editorKey =
      GlobalKey<ExtendedImageEditorState>();
  bool _isProcessing = false;
  double? _aspectRatio = CropAspectRatios.custom;

  Future<void> _cropImage() async {
    if (_isProcessing) return;
    setState(() => _isProcessing = true);

    try {
      final editor = editorKey.currentState;
      final cropRect = editor?.getCropRect();
      final action = editor?.editAction;
      if (cropRect == null || action == null) {
        throw StateError('تعذر قراءة إطار القص.');
      }

      final options = ImageEditorOption();
      if (action.needCrop) {
        options.addOption(ClipOption.fromRect(cropRect));
      }
      if (action.hasRotateDegrees) {
        options.addOption(RotateOption(action.rotateDegrees.round()));
      }
      if (action.needFlip) {
        options.addOption(
          FlipOption(horizontal: action.rotationYRadians != 0, vertical: false),
        );
      }

      final result = await ImageEditor.editImage(
        image: await widget.imageFile.readAsBytes(),
        imageEditorOption: options,
      );
      if (result == null || result.isEmpty) {
        throw StateError('لم يُنتج محرر القص ملفاً صالحاً.');
      }

      final file = await TemporaryImageStore.writeJpeg(
        result,
        prefix: 'cropped_',
      );
      if (!mounted) return;
      Navigator.of(context).pop(file);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر حفظ القص. حاول مرة أخرى.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تعديل الصورة'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'تأكيد القص',
            onPressed: _isProcessing ? null : _cropImage,
          ),
        ],
      ),
      body: _isProcessing
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                Expanded(
                  child: ExtendedImage.file(
                    widget.imageFile,
                    fit: BoxFit.contain,
                    mode: ExtendedImageMode.editor,
                    extendedImageEditorKey: editorKey,
                    initEditorConfigHandler: (ExtendedImageState? state) {
                      return EditorConfig(
                        maxScale: 8,
                        cropRectPadding: const EdgeInsets.all(20),
                        hitTestSize: 24,
                        initCropRectType: InitCropRectType.imageRect,
                        cropAspectRatio: _aspectRatio,
                        cornerSize: const Size(30, 5),
                      );
                    },
                  ),
                ),
                Container(
                  color: const Color(0xFF1E293B),
                  padding: const EdgeInsets.all(8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: <Widget>[
                        _buildAspectRatioChip(
                          'Original',
                          CropAspectRatios.original,
                        ),
                        _buildAspectRatioChip(
                          'Square',
                          CropAspectRatios.ratio1_1,
                        ),
                        _buildAspectRatioChip('3 × 2', 3 / 2),
                        _buildAspectRatioChip(
                          '4 × 3',
                          CropAspectRatios.ratio4_3,
                        ),
                        _buildAspectRatioChip(
                          '16 × 9',
                          CropAspectRatios.ratio16_9,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildAspectRatioChip(String label, double? ratio) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: _aspectRatio == ratio,
        onSelected: (selected) {
          setState(() {
            _aspectRatio = selected ? ratio : CropAspectRatios.custom;
          });
        },
      ),
    );
  }
}
