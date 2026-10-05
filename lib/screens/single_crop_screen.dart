import 'dart:io';
import 'dart:math' as math;

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

  /// Snaps the editor's crop rectangle to whole pixels and to the image bounds.
  ///
  /// Two guarantees are required by the native editor:
  ///
  /// * at least one pixel of content — `ClipOption` asserts `width > 0` and
  ///   `height > 0`, and Android's `Bitmap.createBitmap` throws when the
  ///   rectangle reaches past the bitmap;
  /// * coordinates inside the bitmap that the clip runs against.
  ///
  /// `getCropRect()` is expressed in the *rotated* pixel space (its bounds go
  /// through the current rotation), which is why the width and height limits
  /// are transposed for a quarter turn. The clip option is added after the
  /// rotate option so both refer to the same space.
  Rect _sanitizeCropRect(
    Rect rect, {
    required int rotateDegrees,
    required Size? imageSize,
  }) {
    final naturalWidth = imageSize?.width;
    final naturalHeight = imageSize?.height;
    final quarterTurn = rotateDegrees % 180 != 0;
    final boundWidth = naturalWidth == null || naturalHeight == null
        ? null
        : (quarterTurn ? naturalHeight : naturalWidth);
    final boundHeight = naturalWidth == null || naturalHeight == null
        ? null
        : (quarterTurn ? naturalWidth : naturalHeight);

    var left = math.max(0.0, rect.left.floorToDouble());
    var top = math.max(0.0, rect.top.floorToDouble());
    var right = math.max(left + 1, rect.right.ceilToDouble());
    var bottom = math.max(top + 1, rect.bottom.ceilToDouble());
    final hasBounds =
        boundWidth != null &&
        boundHeight != null &&
        boundWidth >= 1 &&
        boundHeight >= 1;
    if (hasBounds) {
      left = left.clamp(0.0, boundWidth - 1);
      top = top.clamp(0.0, boundHeight - 1);
      right = right.clamp(left + 1, boundWidth);
      bottom = bottom.clamp(top + 1, boundHeight);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

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

      final image = editor?.image;
      final imageSize = image == null
          ? null
          : Size(image.width.toDouble(), image.height.toDouble());
      final rotateDegrees = action.hasRotateDegrees
          ? action.rotateDegrees.round()
          : 0;

      // Order matters: the native handler applies the options in the order they
      // are added, and `getCropRect()` reports coordinates in the rotated
      // space, so rotate/flip must happen before the clip.
      final options = ImageEditorOption();
      if (action.hasRotateDegrees) {
        options.addOption(RotateOption(rotateDegrees));
      }
      if (action.needFlip) {
        options.addOption(
          FlipOption(horizontal: action.rotationYRadians != 0, vertical: false),
        );
      }
      if (action.needCrop) {
        options.addOption(
          ClipOption.fromRect(
            _sanitizeCropRect(
              cropRect,
              rotateDegrees: rotateDegrees,
              imageSize: imageSize,
            ),
          ),
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
                          'الأصلي',
                          CropAspectRatios.original,
                        ),
                        _buildAspectRatioChip(
                          'مربع',
                          CropAspectRatios.ratio1_1,
                        ),
                        _buildAspectRatioChip('3 : 2', 3 / 2),
                        _buildAspectRatioChip(
                          '4 : 3',
                          CropAspectRatios.ratio4_3,
                        ),
                        _buildAspectRatioChip(
                          '16 : 9',
                          CropAspectRatios.ratio16_9,
                        ),
                        _buildAspectRatioChip('حر', CropAspectRatios.custom),
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
