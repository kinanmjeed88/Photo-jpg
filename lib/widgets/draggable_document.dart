import 'package:flutter/material.dart';
import '../providers/app_state.dart';

class DraggableResizableDocument extends StatefulWidget {
  final ScannedDocument document;
  final int index;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final void Function(int index, double dx, double dy, double width, double height, int pageIndex) onLayoutUpdate;
  final double canvasWidth;
  final double canvasHeight;

  const DraggableResizableDocument({
    super.key,
    required this.document,
    required this.index,
    required this.isSelected,
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
  late int pageIndex;

  @override
  void initState() {
    super.initState();
    dx = widget.document.dx;
    dy = widget.document.dy;
    width = widget.document.width;
    height = widget.document.height;
    pageIndex = widget.document.pageIndex;
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
      pageIndex = widget.document.pageIndex;
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      dx += details.delta.dx;
      dy += details.delta.dy;
    });
  }

  void _onPanEnd(DragEndDetails details) {
    _triggerLayoutUpdate();
  }

  void _onResizeUpdate(DragUpdateDetails details) {
    setState(() {
      // Allow scale up to aspect ratio or freeform?
      // Since it's a 2D resize handle on the bottom right:
      final double newWidth = width + details.delta.dx;
      final double newHeight = height + details.delta.dy;

      // Enforce minimum size
      if (newWidth > 50) width = newWidth;
      if (newHeight > 50) height = newHeight;
    });
  }

  void _onResizeEnd(DragEndDetails details) {
    _triggerLayoutUpdate();
  }

  void _triggerLayoutUpdate() {
    int finalPageIndex = pageIndex;
    double finalDy = dy;

    // Auto-pagination logic based on center of document
    final docCenterY = dy + (height / 2);

    if (docCenterY > widget.canvasHeight) {
      finalPageIndex += 1;
      finalDy = 0; // wrap to top of next page
    } else if (docCenterY < 0 && pageIndex > 0) {
      finalPageIndex -= 1;
      finalDy = widget.canvasHeight - height; // wrap to bottom of prev page
    }

    widget.onLayoutUpdate(widget.index, dx, finalDy, width, height, finalPageIndex);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: dx,
      top: dy,
      child: GestureDetector(
        onTap: widget.onTap,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            border: widget.isSelected
                ? Border.all(color: Colors.blueAccent, width: 3)
                : null,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: Image.file(widget.document.file, fit: BoxFit.contain),
              ),
              if (widget.isSelected) ...[
                // Top Right: Delete Button
                Positioned(
                  top: -12,
                  right: -12,
                  child: GestureDetector(
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
                  top: -12,
                  left: -12,
                  child: GestureDetector(
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
                  bottom: -12,
                  right: -12,
                  child: GestureDetector(
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
        ),
      ),
    );
  }
}
