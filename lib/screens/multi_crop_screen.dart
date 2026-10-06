import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../services/image_pipeline.dart';
import '../services/scanner_service.dart';
import '../services/temporary_image_store.dart';

/// Minimum crop box edge in layout pixels. Matches the documented 48 px touch
/// target, so a box always stays big enough to grab and never collapses into an
/// invisible dot.
const double _minimumCropBoxSize = 48;

class CropRect {
  CropRect(this.left, this.top, this.width, this.height);

  double left;
  double top;
  double width;
  double height;
}

Future<List<File>> _runMultiCropIsolate(Map<String, dynamic> args) {
  return Isolate.run(() => _processMultiCrop(args));
}

List<File> _processMultiCrop(Map<String, dynamic> args) {
  final String imagePath = args['imagePath'];
  final List<Map<String, double>> rects = (args['rects'] as List)
      .cast<Map<String, double>>();
  final List<String> outputPaths = (args['outputPaths'] as List).cast<String>();

  cv.Mat? src;
  List<File> croppedFiles = [];

  try {
    src = cv.imread(imagePath, flags: cv.IMREAD_COLOR);
    if (src.isEmpty) return [];

    for (int i = 0; i < rects.length; i++) {
      final rect = rects[i];
      int l = rect['left']!.toInt();
      int t = rect['top']!.toInt();
      int w = rect['width']!.toInt();
      int h = rect['height']!.toInt();

      l = math.max(0, l);
      t = math.max(0, t);
      if (l + w > src.cols) w = src.cols - l;
      if (t + h > src.rows) h = src.rows - t;

      if (w <= 0 || h <= 0) continue;

      cv.Mat cropped = src.region(cv.Rect(l, t, w, h));

      if (i >= outputPaths.length) continue;
      final outputPath = outputPaths[i];
      if (cv.imwrite(outputPath, cropped)) {
        croppedFiles.add(File(outputPath));
      }
      cropped.dispose();
    }
  } catch (_) {
    // A failed worker yields an empty result and preserves the source image.
  } finally {
    src?.dispose();
  }

  return croppedFiles;
}

class MultiCropScreen extends StatefulWidget {
  final File imageFile;
  final List<DocumentRegion> suggestedRegions;
  final Future<SmartScanResult?> Function()? onReanalyze;
  final bool includeReanalyzedAcceptedFiles;

  const MultiCropScreen({
    super.key,
    required this.imageFile,
    this.suggestedRegions = const <DocumentRegion>[],
    this.onReanalyze,
    this.includeReanalyzedAcceptedFiles = true,
  });

  @override
  State<MultiCropScreen> createState() => _MultiCropScreenState();
}

class _MultiCropScreenState extends State<MultiCropScreen> {
  final List<CropRect> _cropRects = [];
  List<DocumentRegion> _suggestedRegions = const <DocumentRegion>[];
  List<File> _acceptedReanalysisFiles = const <File>[];
  bool _allowFullFrameFallback = true;
  bool _isProcessing = false;
  ImageProvider? _imageProvider;
  Size? _imageSize;
  final GlobalKey _imageKey = GlobalKey();

  int get _maxCropBoxes =>
      math.min(20, math.max(5, _suggestedRegions.length)).toInt();

  @override
  void initState() {
    super.initState();
    _suggestedRegions = List<DocumentRegion>.unmodifiable(
      widget.suggestedRegions,
    );
    _allowFullFrameFallback = widget.suggestedRegions.isEmpty;
    _imageProvider = FileImage(widget.imageFile);
    _loadImageSize();
  }

  Future<void> _loadImageSize() async {
    // Measured off the UI isolate. The file was normalised at intake, so its
    // pixel grid matches what `Image` paints and what OpenCV decodes.
    final dimensions = await readOrientedDimensions(widget.imageFile);
    if (!mounted) return;
    if (dimensions != null) {
      setState(() {
        _imageSize = Size(dimensions.$1, dimensions.$2);
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _seedSuggestedRegions();
    });
  }

  /// Size of the drawn image in layout coordinates, or `null` before layout.
  Size? get _displayedSize {
    final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final size = box.size;
    return size.width > 0 && size.height > 0 ? size : null;
  }

  /// Keeps a crop box inside the drawn image.
  void _moveCropBox(CropRect rect, Offset delta) {
    final bounds = _displayedSize;
    if (bounds == null) return;
    final maxLeft = math.max(0.0, bounds.width - rect.width);
    final maxTop = math.max(0.0, bounds.height - rect.height);
    rect.left = (rect.left + delta.dx).clamp(0.0, maxLeft).toDouble();
    rect.top = (rect.top + delta.dy).clamp(0.0, maxTop).toDouble();
  }

  /// Resizes a crop box without letting it leave the image or collapse.
  void _resizeCropBox(CropRect rect, Offset delta) {
    final bounds = _displayedSize;
    if (bounds == null) return;
    final availableWidth = math.max(
      _minimumCropBoxSize,
      bounds.width - rect.left,
    );
    final availableHeight = math.max(
      _minimumCropBoxSize,
      bounds.height - rect.top,
    );
    rect.width = (rect.width + delta.dx)
        .clamp(_minimumCropBoxSize, availableWidth)
        .toDouble();
    rect.height = (rect.height + delta.dy)
        .clamp(_minimumCropBoxSize, availableHeight)
        .toDouble();
  }

  void _seedSuggestedRegions() {
    if (_cropRects.isNotEmpty ||
        _suggestedRegions.isEmpty ||
        _imageSize == null) {
      return;
    }
    final imageBox = _imageKey.currentContext?.findRenderObject() as RenderBox?;
    if (imageBox == null ||
        imageBox.size.width <= 0 ||
        imageBox.size.height <= 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _seedSuggestedRegions();
      });
      return;
    }
    final displayWidth = imageBox.size.width;
    final displayHeight = imageBox.size.height;
    final scaleX = displayWidth / _imageSize!.width;
    final scaleY = displayHeight / _imageSize!.height;
    final seeded = _suggestedRegions
        .take(_maxCropBoxes)
        .map((region) {
          // Every clamp has a provably valid range: the origin leaves room for
          // the minimum box, and each size keeps that minimum while stopping at
          // the image edge. `num.clamp` throws when its bounds are inverted.
          final maxLeft = math.max(0.0, displayWidth - _minimumCropBoxSize);
          final maxTop = math.max(0.0, displayHeight - _minimumCropBoxSize);
          final left = (region.left * scaleX).clamp(0.0, maxLeft).toDouble();
          final top = (region.top * scaleY).clamp(0.0, maxTop).toDouble();
          return CropRect(
            left,
            top,
            (region.width * scaleX)
                .clamp(
                  _minimumCropBoxSize,
                  math.max(_minimumCropBoxSize, displayWidth - left),
                )
                .toDouble(),
            (region.height * scaleY)
                .clamp(
                  _minimumCropBoxSize,
                  math.max(_minimumCropBoxSize, displayHeight - top),
                )
                .toDouble(),
          );
        })
        .toList(growable: false);
    if (mounted && seeded.isNotEmpty) {
      setState(() => _cropRects.addAll(seeded));
    }
  }

  void _addCropBox() {
    if (_cropRects.length >= _maxCropBoxes) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('الحد الأقصى هو $_maxCropBoxes مربعات قص')),
      );
      return;
    }
    final bounds = _displayedSize;
    setState(() {
      if (bounds == null) {
        _cropRects.add(
          CropRect(
            _minimumCropBoxSize * 2,
            _minimumCropBoxSize * 2,
            _minimumCropBoxSize * 4,
            _minimumCropBoxSize * 4,
          ),
        );
        return;
      }
      // A centred box is what the user almost always wants as a starting point.
      final width = math.max(_minimumCropBoxSize, bounds.width * 0.5);
      final height = math.max(_minimumCropBoxSize, bounds.height * 0.5);
      _cropRects.add(
        CropRect(
          ((bounds.width - width) / 2)
              .clamp(0.0, math.max(0.0, bounds.width - width))
              .toDouble(),
          ((bounds.height - height) / 2)
              .clamp(0.0, math.max(0.0, bounds.height - height))
              .toDouble(),
          width,
          height,
        ),
      );
    });
  }

  /// Repaints after a resize drag.
  ///
  /// The crop boxes are plain mutable state owned by this screen, so the overlay
  /// only follows a drag through `setState`; keeping the callback named also
  /// avoids a deeply nested inline closure on the marker widget.
  void _onResize(CropRect rect, Offset delta) {
    setState(() => _resizeCropBox(rect, delta));
  }

  void _removeCropBox(int index) {
    setState(() {
      _cropRects.removeAt(index);
    });
  }

  Future<void> _reanalyze() async {
    final reanalyze = widget.onReanalyze;
    if (reanalyze == null || _isProcessing) return;
    setState(() => _isProcessing = true);
    try {
      final result = await reanalyze();
      if (!mounted || result == null) return;
      setState(() {
        _acceptedReanalysisFiles = widget.includeReanalyzedAcceptedFiles
            ? List<File>.unmodifiable(result.files)
            : const <File>[];
        _suggestedRegions = List<DocumentRegion>.unmodifiable(
          result.manualReviewRegions,
        );
        _allowFullFrameFallback =
            _allowFullFrameFallback && result.manualReviewRegions.isEmpty;
        _cropRects.clear();
      });
      if (result.files.isEmpty && result.manualReviewRegions.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لم يعثر التحليل على حدود موثوقة.')),
        );
      } else if (result.manualReviewRegions.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'أعيد التحليل: ${result.files.length} قص مقبول و${result.manualReviewRegions.length} منطقة للمراجعة.',
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('أعيد التحليل وقُبلت ${result.files.length} قصوص.'),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر إعادة تحليل الصورة.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _finishCropping() async {
    if (_cropRects.isEmpty) {
      Navigator.pop(
        context,
        _acceptedReanalysisFiles.isNotEmpty
            ? _acceptedReanalysisFiles
            : _suggestedRegions.isEmpty && _allowFullFrameFallback
            ? <File>[widget.imageFile]
            : const <File>[],
      );
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final RenderBox? imageBox =
          _imageKey.currentContext?.findRenderObject() as RenderBox?;
      if (imageBox == null || _imageSize == null) {
        throw Exception("Could not determine image layout.");
      }

      final widgetSize = imageBox.size;
      final double scaleX = _imageSize!.width / widgetSize.width;
      final double scaleY = _imageSize!.height / widgetSize.height;

      final mappedRects = _cropRects.map((rect) {
        final left = rect.left.clamp(0.0, widgetSize.width - 1).toDouble();
        final top = rect.top.clamp(0.0, widgetSize.height - 1).toDouble();
        final right = (rect.left + rect.width)
            .clamp(left + 1, widgetSize.width)
            .toDouble();
        final bottom = (rect.top + rect.height)
            .clamp(top + 1, widgetSize.height)
            .toDouble();
        return {
          'left': left * scaleX,
          'top': top * scaleY,
          'width': (right - left) * scaleX,
          'height': (bottom - top) * scaleY,
        };
      }).toList();

      final outputPaths = await Future.wait(
        List<Future<String>>.generate(
          mappedRects.length,
          (index) =>
              TemporaryImageStore.createPath('manual_crop_', suffix: '-$index'),
        ),
      );
      final args = {
        'imagePath': widget.imageFile.path,
        'rects': mappedRects,
        'outputPaths': outputPaths,
      };

      final croppedFiles = await _runMultiCropIsolate(args);

      final outputFiles = <File>[..._acceptedReanalysisFiles, ...croppedFiles];
      if (mounted) {
        Navigator.pop(
          context,
          outputFiles.isEmpty &&
                  _suggestedRegions.isEmpty &&
                  _allowFullFrameFallback
              ? <File>[widget.imageFile]
              : outputFiles,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('تعذر حفظ القص اليدوي.')));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تحديد متعدد للمستندات'),
        actions: [
          if (widget.onReanalyze != null)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'إعادة التحليل',
              onPressed: _isProcessing ? null : _reanalyze,
            ),
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'تأكيد',
            onPressed: _isProcessing ? null : _finishCropping,
          ),
        ],
      ),
      body: _isProcessing
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Text(
                    _suggestedRegions.isEmpty
                        ? 'حدد إطارات حول المستندات. يمكنك إضافة حتى $_maxCropBoxes إطارات.'
                        : 'تم تحديد المناطق غير المؤكدة تلقائياً. راجعها ثم اضغط تأكيد أو أعد التحليل.',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (_suggestedRegions.any((region) => region.reason.isNotEmpty))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: _suggestedRegions
                          .where((region) => region.reason.isNotEmpty)
                          .map(
                            (region) => Chip(
                              label: Text(region.reason),
                              backgroundColor: Colors.orange.withValues(
                                alpha: 0.18,
                              ),
                              side: const BorderSide(color: Colors.orange),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ),
                Expanded(
                  child: InteractiveViewer(
                    maxScale: 5.0,
                    child: Center(
                      child: Stack(
                        key: _imageKey,
                        children: [
                          if (_imageProvider != null)
                            Image(image: _imageProvider!, fit: BoxFit.contain),
                          ..._cropRects.asMap().entries.map((entry) {
                            final idx = entry.key;
                            final rect = entry.value;
                            return Positioned(
                              left: rect.left,
                              top: rect.top,
                              child: GestureDetector(
                                // The box is moved through the clamped helper
                                // instead of raw deltas, so it can never be
                                // dragged off the image.
                                onPanUpdate: (details) => setState(
                                  () => _moveCropBox(rect, details.delta),
                                ),
                                child: Container(
                                  width: rect.width,
                                  height: rect.height,
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: Colors.orange,
                                      width: 2,
                                    ),
                                    color: Colors.orange.withValues(alpha: 0.1),
                                  ),
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Positioned(
                                        top: -30,
                                        right: -30,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => _removeCropBox(idx),
                                          child: Container(
                                            width: 60,
                                            height: 60,
                                            color: Colors.transparent,
                                            child: const Center(
                                              child: CircleAvatar(
                                                radius: 12,
                                                backgroundColor: Colors.red,
                                                child: Icon(
                                                  Icons.close,
                                                  size: 16,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Positioned(
                                        bottom: -30,
                                        right: -30,
                                        child: GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          // Resizing keeps the documented
                                          // 48 px minimum and stops at the
                                          // image edge.
                                          onPanUpdate: (details) =>
                                              _onResize(rect, details.delta),
                                          child: Container(
                                            width: 60,
                                            height: 60,
                                            color: Colors.transparent,
                                            child: const Center(
                                              child: CircleAvatar(
                                                radius: 12,
                                                backgroundColor: Colors.blue,
                                                child: Icon(
                                                  Icons.open_in_full,
                                                  size: 16,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: ElevatedButton.icon(
                    onPressed: _addCropBox,
                    icon: const Icon(Icons.add_box),
                    label: const Text('إضافة إطار قص'),
                  ),
                ),
              ],
            ),
    );
  }
}
