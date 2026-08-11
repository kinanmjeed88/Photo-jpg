import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import '../providers/app_state.dart';

class DraggableResizableDocument extends StatefulWidget {
  final ScannedDocument document;
  final int pageIndex;
  final int docIndex;
  final bool isSelected;
  final bool addFrame;
  final VoidCallback onTap;
  final void Function(
    int pageIndex,
    int docIndex,
    double dx,
    double dy,
    double width,
    double height,
    int rotationAngle,
  )
  onLayoutUpdate;
  final void Function(
    int sourcePageIndex,
    int docIndex,
    ScannedDocument doc,
    double dx,
    double dy,
  )
  onCrossPageMove;
  final double canvasWidth;
  final double canvasHeight;
  final double canvasScale;
  final VoidCallback? onGestureStart;
  final void Function(double newScale, Offset delta)? onTransformUpdate;
  final ValueChanged<double>? onHandleResize;
  final VoidCallback? onGestureEnd;

  const DraggableResizableDocument({
    super.key,
    required this.document,
    required this.pageIndex,
    required this.docIndex,
    required this.isSelected,
    required this.addFrame,
    required this.onTap,
    required this.onLayoutUpdate,
    required this.onCrossPageMove,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.canvasScale,
    this.onGestureStart,
    this.onTransformUpdate,
    this.onHandleResize,
    this.onGestureEnd,
  });

  @override
  State<DraggableResizableDocument> createState() =>
      _DraggableResizableDocumentState();
}

class _DraggableResizableDocumentState
    extends State<DraggableResizableDocument> {
  late double dx;
  late double dy;
  late double width;
  late double height;
  late int rotationAngle;
  bool isDragging = false;
  double _baseScale = 1.0; // Snapshot of scale at gesture start
  bool _isResizing = false;
  double _handleBaseScale = 1.0;
  double _accumulatedDrag = 0.0;

  @override
  void initState() {
    super.initState();
    dx = widget.document.dx;
    dy = widget.document.dy;
    width = widget.document.width;
    height = widget.document.height;
    rotationAngle = widget.document.rotationAngle;
  }

  @override
  void didUpdateWidget(DraggableResizableDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document != widget.document) {
      dx = widget.document.dx;
      dy = widget.document.dy;
      width = widget.document.width;
      height = widget.document.height;
      rotationAngle = widget.document.rotationAngle;
    }
  }

  double get _documentAspectRatio {
    // Determine aspect ratio considering rotation
    bool isRotated = rotationAngle % 180 != 0;

    if (widget.document.originalHeight > 0) {
      double baseRatio =
          widget.document.originalWidth / widget.document.originalHeight;
      return isRotated ? (1 / baseRatio) : baseRatio;
    }
    return 1.0;
  }

  Widget _buildDocumentImage() {
    return RepaintBoundary(
      child: SizedBox(
        width: width,
        height: height,
        child: AspectRatio(
          aspectRatio: _documentAspectRatio,
          child: Container(
            decoration: BoxDecoration(
              border: widget.isSelected
                  ? Border.all(color: Colors.blueAccent, width: 3)
                  : (widget.addFrame
                        ? Border.all(color: Colors.black, width: 1.0)
                        : null),
            ),
            child: RotatedBox(
              quarterTurns: rotationAngle ~/ 90,
              child: Image.file(widget.document.file, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHandleUI() {
    return Container(
      width: 120,
      height: 120,
      color: Colors.transparent,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: _isResizing ? Colors.orange : Colors.blue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 4, spreadRadius: 1),
            ],
          ),
          padding: const EdgeInsets.all(12),
          child: const Icon(Icons.open_in_full, size: 32, color: Colors.white),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    debugPrint('isSelected: ${widget.isSelected}, isDragging: $isDragging');

    Widget documentWidget = SizedBox(
      width: width,
      height: height,
      child: Transform.scale(
        scale: widget.document.scale,
        alignment: Alignment.center,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.deferToChild,
              onTapDown: (_) {
                // CRITICAL FIX: Restore tap selection for Z-index ordering
                // Using onTapDown ensures it fires before scale gestures win the arena
                // ignore: unnecessary_null_comparison
                if (widget.onTap != null) widget.onTap();
              },
              onScaleStart: (details) {
                _baseScale = widget.document.scale;
                if (widget.onGestureStart != null) widget.onGestureStart!();
              },
              onScaleUpdate: (details) {
                final double newScale = (_baseScale * details.scale).clamp(0.3, 3.0);
                if (widget.onTransformUpdate != null) {
                  widget.onTransformUpdate!(newScale, details.focalPointDelta);
                }
              },
              onScaleEnd: (details) {
                if (widget.onGestureEnd != null) widget.onGestureEnd!();
              },
              child: _buildDocumentImage(),
            ),

            if (widget.isSelected)
              Positioned(
                bottom: -60 / widget.document.scale,
                right: -60 / widget.document.scale,
                child: SizedBox(
                  // Massive 120x120 physical thumb target that never shrinks
                  width: 120 / widget.document.scale,
                  height: 120 / widget.document.scale,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (details) {
                      HapticFeedback.selectionClick();
                      setState(() {
                        _isResizing = true;
                        _handleBaseScale = widget.document.scale;
                        _accumulatedDrag = 0.0;
                      });
                    },
                    onPanUpdate: (details) {
                      // Handle is physically locked to the RIGHT corner.
                      // Right (+dx) and Down (+dy) ALWAYS mean OUTWARD. NO RTL INVERSION.
                      final double dx = details.delta.dx;
                      final double dy = details.delta.dy;

                      // Smooth Euclidean projection for diagonal dragging
                      final double diagonalDrag = (dx + dy) / math.sqrt(2);
                      _accumulatedDrag += diagonalDrag;

                      // Convert drag pixels to scale (150px = 1.0 scale change)
                      final double newScale =
                          (_handleBaseScale + (_accumulatedDrag / 150.0))
                              .clamp(0.3, 3.0);

                      if (widget.onHandleResize != null) {
                        widget.onHandleResize!(newScale);
                      }
                    },
                    onPanEnd: (_) => setState(() => _isResizing = false),
                    onPanCancel: () => setState(() => _isResizing = false),
                    child: Center(
                      child: Transform.scale(
                        scale: 1.0 / widget.document.scale,
                        alignment: Alignment.center,
                        child: SizedBox(
                          width: 120,
                          height: 120,
                          child: Center(child: _buildHandleUI()),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Positioned(
      left: widget.document.position.dx,
      top: widget.document.position.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Stack(clipBehavior: Clip.none, children: [documentWidget]),
      ),
    );
  }
}
