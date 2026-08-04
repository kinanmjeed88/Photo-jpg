import 'package:flutter/material.dart';
import 'dart:math' as math;
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

      // Strict bounds clamping for drag
      dx = math.max(0.0, math.min(dx, widget.canvasWidth - width));
      dy = math.max(0.0, math.min(dy, widget.canvasHeight - height));
    });
  }

  void _onPanEnd(DragEndDetails details) {
    _triggerLayoutUpdate();
  }

  void _onResizeUpdate(DragUpdateDetails details) {
    setState(() {
      // Allow scale up to aspect ratio or freeform?
      // Since it's a 2D resize handle on the bottom right:
      double newWidth = width + details.delta.dx;
      double newHeight = height + details.delta.dy;

      // Enforce minimum size
      if (newWidth < 50) newWidth = 50;
      if (newHeight < 50) newHeight = 50;

      // Ensure resize doesn't push the document out of bounds
      newWidth = math.min(newWidth, widget.canvasWidth - dx);
      newHeight = math.min(newHeight, widget.canvasHeight - dy);

      width = newWidth;
      height = newHeight;
    });
  }

  void _onResizeEnd(DragEndDetails details) {
    _triggerLayoutUpdate();
  }

  void _triggerLayoutUpdate() {
    // We enforce strictly no automatic cross-page drag. Document stays on current page.
    widget.onLayoutUpdate(widget.index, dx, dy, width, height, pageIndex);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: dx - 12,
      top: dy - 12,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: widget.onTap,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
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
                child: Container(
                  decoration: BoxDecoration(
                    border: widget.isSelected
                        ? Border.all(color: Colors.blueAccent, width: 3)
                        : null,
                  ),
                  child: Image.file(widget.document.file, fit: BoxFit.contain),
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
        ),
      ),
    );
  }
}
