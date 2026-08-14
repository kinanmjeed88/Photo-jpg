import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../providers/app_state.dart';

class DraggableResizableDocument extends StatefulWidget {
  const DraggableResizableDocument({
    super.key,
    required this.document,
    required this.isSelected,
    required this.addFrame,
    required this.canvasWidth,
    required this.canvasHeight,
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
  final double canvasScale;
  final ValueChanged<String> onTap;
  final void Function(String documentId, double dx, double dy, double scale)
  onLayoutUpdate;
  final void Function(String documentId, double dx, double dy) onCrossPageMove;
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
    final maxX = math.max(0, widget.canvasWidth - scaledWidth);
    final maxY = math.max(0, widget.canvasHeight - scaledHeight);
    final dragOffset = details.focalPoint - _startFocalPoint;
    setState(() {
      _scale = proposedScale;
      _dx = (_startDx + dragOffset.dx / widget.canvasScale)
          .clamp(0, maxX)
          .toDouble();
      _dy = (_startDy + dragOffset.dy / widget.canvasScale)
          .clamp(-scaledHeight * 0.2, maxY + scaledHeight * 0.2)
          .toDouble();
    });
    _emitLayout();
  }

  void _endTransform() {
    if (_dy < 0 ||
        _dy + widget.document.height * _scale > widget.canvasHeight) {
      widget.onCrossPageMove(widget.document.id, _dx, _dy);
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
    final maxScaleX = widget.canvasWidth / widget.document.width;
    final maxScaleY = widget.canvasHeight / widget.document.height;
    final boundedScale = math.min(
      proposedScale,
      math.min(maxScaleX, maxScaleY),
    );
    setState(() => _scale = boundedScale);
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
                  right: -24,
                  bottom: -24,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => _beginResize(),
                    onPanUpdate: _updateResize,
                    onPanEnd: (_) => _endResize(),
                    onPanCancel: _endResize,
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
            ],
          ),
        ),
      ),
    );
  }
}
