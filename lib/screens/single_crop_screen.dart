import 'dart:io';
import 'package:flutter/material.dart';
import 'package:extended_image/extended_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image_editor/image_editor.dart';
import 'package:path/path.dart' as p;

class SingleCropScreen extends StatefulWidget {
  final File imageFile;

  const SingleCropScreen({super.key, required this.imageFile});

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
    setState(() {
      _isProcessing = true;
    });

    try {
      final ExtendedImageEditorState? state = editorKey.currentState;
      if (state == null) {
        setState(() => _isProcessing = false);
        return;
      }

      final Rect? cropRect = state.getCropRect();
      final EditActionDetails? action = state.editAction;
      if (cropRect == null || action == null) {
        setState(() => _isProcessing = false);
        return;
      }

      final img = await widget.imageFile.readAsBytes();

      final ImageEditorOption option = ImageEditorOption();

      if (action.needCrop) {
        option.addOption(ClipOption.fromRect(cropRect));
      }
      if (action.hasRotateDegrees) {
        option.addOption(RotateOption(action.rotateDegrees.toInt()));
      }
      if (action.needFlip) {
        option.addOption(
          FlipOption(horizontal: action.rotationYRadians != 0, vertical: false),
        );
      }

      final result = await ImageEditor.editImage(
        image: img,
        imageEditorOption: option,
      );

      if (result == null) {
        setState(() => _isProcessing = false);
        return;
      }

      final tempDir = await getTemporaryDirectory();
      final tempPath = p.join(
        tempDir.path,
        'cropped_\${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      final file = File(tempPath);
      await file.writeAsBytes(result);

      if (!mounted) return;
      Navigator.of(context).pop(file);
    } catch (e) {
      debugPrint('Crop failed: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تعديل الصورة'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _isProcessing ? null : _cropImage,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ExtendedImage.file(
              widget.imageFile,
              fit: BoxFit.contain,
              mode: ExtendedImageMode.editor,
              extendedImageEditorKey: editorKey,
              initEditorConfigHandler: (ExtendedImageState? state) {
                return EditorConfig(
                  maxScale: 8.0,
                  cropRectPadding: const EdgeInsets.all(20.0),
                  hitTestSize: 24.0, // 48px hitboxes -> 48px minimum crop size
                  initCropRectType: InitCropRectType.imageRect,
                  cropAspectRatio: _aspectRatio,
                  cornerSize: const Size(30.0, 5.0),
                );
              },
            ),
          ),
          Container(
            color: const Color(0xFF1E293B),
            padding: const EdgeInsets.all(8.0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  _buildAspectRatioChip('Original', CropAspectRatios.original),
                  _buildAspectRatioChip('square', CropAspectRatios.ratio1_1),
                  _buildAspectRatioChip('3x2', 3.0 / 2.0),
                  _buildAspectRatioChip('4x3', CropAspectRatios.ratio4_3),
                  _buildAspectRatioChip('16x9', CropAspectRatios.ratio16_9),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAspectRatioChip(String label, double? ratio) {
    final isSelected = _aspectRatio == ratio;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: ChoiceChip(
        label: Text(label),
        selected: isSelected,
        onSelected: (bool selected) {
          if (selected) {
            setState(() {
              _aspectRatio = ratio;
            });
          } else {
            setState(() {
              _aspectRatio = CropAspectRatios.custom;
            });
          }
        },
      ),
    );
  }
}
