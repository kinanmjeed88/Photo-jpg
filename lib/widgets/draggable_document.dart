import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../providers/app_state.dart';

enum CrossPageDirection { left, right, up, down }

class DraggableResizableDocument extends StatefulWidget {
  const DraggableResizableDocument({
    super.key,
    required this.document,
    required this.isSelected,
    required this.addFrame,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.canvasGuide,
    required this.canvasScale,
    required this.onTap,
    required this.onLayoutUpdate,
    required this.onCrossPageMove,
    this.onGestureStart,
    this.onGestureEnd,
  });

  final ScannedDocument document;
  final bool isSelected;
  final bool addFrame;
  final double canvasWidth;
  final double canvasHeight;
  final Rect canvasGuide;
  final double canvasScale;
  final ValueChanged<String> onTap;
  final void Function(String documentId, double dx, double dy, double scale)
  onLayoutUpdate;
  final void Function(
    String documentId,
    double dx,
    double dy,
    CrossPageDirection direction,
  )
  onCrossPageMove;
  final VoidCallback? onGestureStart;
  final VoidCallback? onGestureEnd;

  @override
  State<DraggableResizableDocument> createState() =>
      _DraggableResizableDocumentState();
}

class _DraggableResizableDocumentState
    extends State<DraggableResizableDocument> {
  late double _dx;
  late double _dy;
  late double _scale;
  double _startDx = 0;
  double _startDy = 0;
  double _startScale = 1;
  Offset _startFocalPoint = Offset.zero;
  double _resizeBaseScale = 1;
  double _resizeDrag = 0;
  bool _isInteracting = false;
  bool _isResizing = false;

  @override
  void initState() {
    super.initState();
    _syncFromDocument();
  }

  @override
  void didUpdateWidget(covariant DraggableResizableDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isInteracting && oldWidget.document != widget.document) {
      _syncFromDocument();
    }
  }

  void _syncFromDocument() {
    _dx = widget.document.dx;
    _dy = widget.document.dy;
    _scale = widget.document.scale;
  }

  void _emitLayout() {
    widget.onLayoutUpdate(widget.document.id, _dx, _dy, _scale);
  }

  void _beginTransform(ScaleStartDetails details) {
    _isInteracting = true;
    _startDx = _dx;
    _startDy = _dy;
    _startScale = _scale;
    _startFocalPoint = details.focalPoint;
    widget.onGestureStart?.call();
  }

  void _updateTransform(ScaleUpdateDetails details) {
    final proposedScale = (_startScale * details.scale)
        .clamp(0.3, 3.0)
        .toDouble();
    final scaledWidth = widget.document.width * proposedScale;
    final scaledHeight = widget.document.height * proposedScale;
    final minX = widget.canvasGuide.left;
    final maxX = math.max(minX, widget.canvasGuide.right - scaledWidth);
    final minY = widget.canvasGuide.top;
    final maxY = math.max(minY, widget.canvasGuide.bottom - scaledHeight);
    final dragOffset = details.focalPoint - _startFocalPoint;
    final horizontalOverscroll = math.max(24, scaledWidth * 0.2);
    final verticalOverscroll = math.max(24, scaledHeight * 0.2);
    setState(() {
      _scale = proposedScale;
      // A bounded overscroll is intentional. It gives every page edge a
      // reliable transfer gesture while keeping the document visually anchored
      // to the current page until the gesture ends.
      _dx = (_startDx + dragOffset.dx / widget.canvasScale)
          .clamp(minX - horizontalOverscroll, maxX + horizontalOverscroll)
          .toDouble();
      _dy = (_startDy + dragOffset.dy / widget.canvasScale)
          .clamp(minY - verticalOverscroll, maxY + verticalOverscroll)
          .toDouble();
    });
    _emitLayout();
  }

  CrossPageDirection? _crossPageDirection() {
    final scaledWidth = widget.document.width * _scale;
    final scaledHeight = widget.document.height * _scale;
    final overflowLeft = math.max(0.0, widget.canvasGuide.left - _dx);
    final overflowRight = math.max(
      0.0,
      (_dx + scaledWidth) - widget.canvasGuide.right,
    );
    final overflowTop = math.max(0.0, widget.canvasGuide.top - _dy);
    final overflowBottom = math.max(
      0.0,
      (_dy + scaledHeight) - widget.canvasGuide.bottom,
    );
    final horizontalOverflow = math.max(overflowLeft, overflowRight);
    final verticalOverflow = math.max(overflowTop, overflowBottom);
    if (horizontalOverflow == 0 && verticalOverflow == 0) return null;
    if (horizontalOverflow >= verticalOverflow) {
      return overflowLeft >= overflowRight
          ? CrossPageDirection.left
          : CrossPageDirection.right;
    }
    return overflowTop >= overflowBottom
        ? CrossPageDirection.up
        : CrossPageDirection.down;
  }

  void _endTransform() {
    final direction = _crossPageDirection();
    if (direction != null) {
      widget.onCrossPageMove(widget.document.id, _dx, _dy, direction);
    } else {
      _emitLayout();
    }
    setState(() => _isInteracting = false);
    widget.onGestureEnd?.call();
  }

  void _beginResize() {
    HapticFeedback.selectionClick();
    _isInteracting = true;
    _isResizing = true;
    _resizeBaseScale = _scale;
    _resizeDrag = 0;
  }

  void _updateResize(DragUpdateDetails details) {
    _resizeDrag += (details.delta.dx + details.delta.dy) / math.sqrt2;
    final proposedScale = (_resizeBaseScale + _resizeDrag / 150).clamp(
      0.3,
      3.0,
    );
    final maxScaleX = widget.canvasGuide.width / widget.document.width;
    final maxScaleY = widget.canvasGuide.height / widget.document.height;
    final boundedScale = math.min(
      proposedScale,
      math.min(maxScaleX, maxScaleY),
    );
    final scaledWidth = widget.document.width * boundedScale;
    final scaledHeight = widget.document.height * boundedScale;
    setState(() {
      _scale = boundedScale;
      _dx = _dx
          .clamp(
            widget.canvasGuide.left,
            math.max(
              widget.canvasGuide.left,
              widget.canvasGuide.right - scaledWidth,
            ),
          )
          .toDouble();
      _dy = _dy
          .clamp(
            widget.canvasGuide.top,
            math.max(
              widget.canvasGuide.top,
              widget.canvasGuide.bottom - scaledHeight,
            ),
          )
          .toDouble();
    });
    _emitLayout();
  }

  void _endResize() {
    setState(() {
      _isResizing = false;
      _isInteracting = false;
    });
    _emitLayout();
  }

  @override
  Widget build(BuildContext context) {
    final scaledWidth = widget.document.width * _scale;
    final scaledHeight = widget.document.height * _scale;
    final imageAspectRatio = widget.document.originalHeight == 0
        ? 1.0
        : widget.document.originalWidth / widget.document.originalHeight;

    return Positioned(
      left: _dx,
      top: _dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        dragStartBehavior: DragStartBehavior.down,
        onTap: () => widget.onTap(widget.document.id),
        onScaleStart: _beginTransform,
        onScaleUpdate: _updateTransform,
        onScaleEnd: (_) => _endTransform(),
        child: SizedBox(
          width: scaledWidth,
          height: scaledHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Container(
                decoration: BoxDecoration(
                  border: widget.isSelected
                      ? Border.all(color: Colors.blueAccent, width: 3)
                      : widget.addFrame
                      ? Border.all(color: Colors.black)
                      : null,
                ),
                child: RotatedBox(
                  quarterTurns: widget.document.rotationAngle ~/ 90,
                  child: AspectRatio(
                    aspectRatio: imageAspectRatio,
                    child: Image.file(
                      widget.document.file,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
              if (widget.isSelected)
                Positioned(
                  right: 4,
                  bottom: 4,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => _beginResize(),
                    onPanUpdate: _updateResize,
                    onPanEnd: (_) => _endResize(),
                    onPanCancel: _endResize,
                    child: SizedBox(
                      width: 56,
                      height: 56,
                      child: Center(
                        child: CircleAvatar(
                          radius: 20,
                          backgroundColor: _isResizing
                              ? Colors.orange
                              : Colors.blue,
                          child: const Icon(
                            Icons.open_in_full,
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
  }
}
