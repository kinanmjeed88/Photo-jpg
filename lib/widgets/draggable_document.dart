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
  final void Function(int pageIndex, int docIndex, double dx, double dy, double width, double height, int rotationAngle) onLayoutUpdate;
  final void Function(int sourcePageIndex, int docIndex, ScannedDocument doc, double dx, double dy) onCrossPageMove;
  final double canvasWidth;
  final double canvasHeight;
  final double canvasScale;
  final VoidCallback? onGestureStart;
  final void Function(double newScale, Offset newPosition)? onTransformUpdate;
  final void Function(double scaleDelta)? onHandleResize;
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
  State<DraggableResizableDocument> createState() => _DraggableResizableDocumentState();
}

class _DraggableResizableDocumentState extends State<DraggableResizableDocument> {
  late double dx;
  late double dy;
  late double width;
  late double height;
  late int rotationAngle;
  bool isDragging = false;
  double _baseScale = 1.0;      // Snapshot of scale at gesture start
  bool _isResizing = false;

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
      double baseRatio = widget.document.originalWidth / widget.document.originalHeight;
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
                  : (widget.addFrame ? Border.all(color: Colors.black, width: 1.0) : null),
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
      width: 60, height: 60,
      color: Colors.transparent,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: _isResizing ? Colors.orange : Colors.blue,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, spreadRadius: 1)],
          ),
          padding: const EdgeInsets.all(6),
          child: const Icon(Icons.open_in_full, size: 16, color: Colors.white),
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
      child: GestureDetector(
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
        child: Transform.scale(
          scale: widget.document.scale,
          alignment: Alignment.center,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              _buildDocumentImage(), // Keep your existing document image widget here

              if (widget.isSelected)
                Positioned( // CRITICAL: Forced to physical Right, NOT Directional
                  bottom: -20 / widget.document.scale,
                  right: -20 / widget.document.scale,
                  child: Transform.scale(
                    scale: 1.0 / widget.document.scale, // Inverse scale to maintain 60x60 physical size
                    alignment: Alignment.center,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) {
                        HapticFeedback.selectionClick();
                        _baseScale = widget.document.scale;
                        setState(() => _isResizing = true);
                      },
                      onPanUpdate: (details) {
                        // Fixed Right Handle math: Right (+dx) or Down (+dy) = Grow.
                        final double dx = details.delta.dx * widget.document.scale;
                        final double dy = details.delta.dy * widget.document.scale;

                        final double magnitude = math.sqrt(dx * dx + dy * dy);
                        final double direction = (dx + dy) >= 0 ? 1.0 : -1.0;
                        final double scaleDelta = magnitude * direction * 0.005;

                        if (widget.onHandleResize != null) {
                          widget.onHandleResize!(scaleDelta);
                        }
                      },
                      onPanEnd: (_) => setState(() => _isResizing = false),
                      onPanCancel: () => setState(() => _isResizing = false),
                      child: _buildHandleUI(), // Keep your existing 60x60 animated handle UI
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    return Positioned(
      left: dx,
      top: dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            documentWidget,
          ],
        ),
      ),
    );
  }
}
