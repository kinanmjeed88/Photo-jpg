import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../providers/app_state.dart';

class DraggableResizableDocument extends StatefulWidget {
  final ScannedDocument document;
  final int pageIndex;
  final int docIndex;
  final bool isSelected;
  final bool addFrame;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final void Function(int pageIndex, int docIndex, double dx, double dy, double width, double height) onLayoutUpdate;
  final double canvasWidth;
  final double canvasHeight;

  const DraggableResizableDocument({
    super.key,
    required this.document,
    required this.pageIndex,
    required this.docIndex,
    required this.isSelected,
    required this.addFrame,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
    required this.onLayoutUpdate,
    required this.canvasWidth,
    required this.canvasHeight,
  });

  @override
  State<DraggableResizableDocument> createState() => _DraggableResizableDocumentState();
}

class _DraggableResizableDocumentState extends State<DraggableResizableDocument> {
  late double dx;
  late double dy;
  late double width;
  late double height;

  @override
  void initState() {
    super.initState();
    dx = widget.document.dx;
    dy = widget.document.dy;
    width = widget.document.width;
    height = widget.document.height;
  }

  @override
  void didUpdateWidget(DraggableResizableDocument oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If external state overrides (like pagination or undo), sync back
    if (oldWidget.document != widget.document) {
      dx = widget.document.dx;
      dy = widget.document.dy;
      width = widget.document.width;
      height = widget.document.height;
    }
  }


  double get _documentAspectRatio {
    if (widget.document.originalHeight > 0) {
      return widget.document.originalWidth / widget.document.originalHeight;
    }
    return 1.0;
  }


  void _onResizeUpdate(DragUpdateDetails details) {
    setState(() {
      // Allow scale up to aspect ratio strictly
      // Since it's a 2D resize handle on the bottom right:
      double newWidth = width + details.delta.dx;

      // Enforce minimum size
      if (newWidth < 50) newWidth = 50;

      double newHeight = newWidth / _documentAspectRatio;

      // Ensure resize doesn't push the document out of bounds
      if (newWidth > widget.canvasWidth - dx) {
        newWidth = widget.canvasWidth - dx;
        newHeight = newWidth / _documentAspectRatio;
      }

      if (newHeight > widget.canvasHeight - dy) {
        newHeight = widget.canvasHeight - dy;
        newWidth = newHeight * _documentAspectRatio;
      }

      width = newWidth;
      height = newHeight;
    });
  }

  void _onResizeEnd(DragEndDetails details) {
    _triggerLayoutUpdate();
  }

  void _triggerLayoutUpdate() {
    // Local layout update within the same page
    widget.onLayoutUpdate(widget.pageIndex, widget.docIndex, dx, dy, width, height);
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> dragData = {
      'document': widget.document,
      'pageIndex': widget.pageIndex,
      'docIndex': widget.docIndex,
      'dx': dx,
      'dy': dy,
      'width': width,
      'height': height,
    };

    return Positioned(
      left: dx - 12,
      top: dy - 12,
      child: Draggable<Map<String, dynamic>>(
        data: dragData,
        feedback: Material(
          color: Colors.transparent,
          child: Container(
            width: width + 24,
            height: height + 24,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 12,
                  top: 12,
                  width: width,
                  height: height,
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: _documentAspectRatio,
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.blueAccent.withOpacity(0.5), width: 3),
                        ),
                        child: Image.file(widget.document.file, fit: BoxFit.contain),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.3,
          child: _buildDocumentContent(),
        ),
        onDragEnd: (details) {
          // DragTarget handles all drops.
        },
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onTap,
          child: _buildDocumentContent(),
        ),
      ),
    );
  }

  Widget _buildDocumentContent() {
    return Container(
      width: width + 24,
      height: height + 24,
      child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 12,
                top: 12,
                width: width,
                height: height,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: _documentAspectRatio,
                    child: Container(
                      decoration: BoxDecoration(
                        border: widget.isSelected
                            ? Border.all(color: Colors.blueAccent, width: 3)
                            : (widget.addFrame ? Border.all(color: Colors.black, width: 1.0) : null),
                      ),
                      child: Image.file(widget.document.file, fit: BoxFit.contain),
                    ),
                  ),
                ),
              ),
              if (widget.isSelected) ...[
                // Top Right: Delete Button
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onDelete,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.redAccent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, color: Colors.white, size: 16),
                    ),
                  ),
                ),
                // Top Left: Edit Button
                Positioned(
                  top: 0,
                  left: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onEdit,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.blueAccent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.edit, color: Colors.white, size: 16),
                    ),
                  ),
                ),
                // Bottom Right: Resize Handle
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanUpdate: _onResizeUpdate,
                    onPanEnd: _onResizeEnd,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                        color: Colors.blueAccent,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.open_in_full, color: Colors.white, size: 16),
                    ),
                  ),
                ),
              ],
            ],
          ),
    );
  }
}
