import 'package:flutter/material.dart';
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
  final double canvasScale;
  final VoidCallback? onDragStarted;

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
    required this.canvasScale,
    this.onDragStarted,
  });

  @override
  State<DraggableResizableDocument> createState() => _DraggableResizableDocumentState();
}

class _DraggableResizableDocumentState extends State<DraggableResizableDocument> {

  Offset _customDragAnchorStrategy(Draggable<Object> draggable, BuildContext context, Offset position) {
    final RenderBox renderObject = context.findRenderObject()! as RenderBox;
    final Offset globalTopLeft = renderObject.localToGlobal(Offset.zero);
    return position - globalTopLeft;
  }

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
      double newWidth = width + details.delta.dx;
      if (newWidth < 50) newWidth = 50;

      double newHeight = newWidth / _documentAspectRatio;

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

    final double hitBoxPadding = 32.0;

    return Positioned(
      left: dx - hitBoxPadding,
      top: dy - hitBoxPadding,
      child: Draggable<Map<String, dynamic>>(
        dragAnchorStrategy: _customDragAnchorStrategy,
        onDragStarted: widget.onDragStarted,
        data: dragData,
        feedback: Material(
          color: Colors.transparent,
          child: SizedBox(
            width: (width + (hitBoxPadding * 2)) * widget.canvasScale,
            height: (height + (hitBoxPadding * 2)) * widget.canvasScale,
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: width + (hitBoxPadding * 2),
                height: height + (hitBoxPadding * 2),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: hitBoxPadding,
                      top: hitBoxPadding,
                      width: width,
                      height: height,
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: _documentAspectRatio,
                          child: Container(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.blueAccent.withValues(alpha: 0.5), width: 3),
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
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.3,
          child: _buildDocumentContent(hitBoxPadding),
        ),
        onDragEnd: (details) {},
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onTap,
          child: _buildDocumentContent(hitBoxPadding),
        ),
      ),
    );
  }

  Widget _buildDocumentContent(double hitBoxPadding) {
    return SizedBox(
      width: width + (hitBoxPadding * 2),
      height: height + (hitBoxPadding * 2),
      child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: hitBoxPadding,
                top: hitBoxPadding,
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
                Positioned(
                  top: hitBoxPadding - 24,
                  right: hitBoxPadding - 24,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onDelete,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                          color: Colors.redAccent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close, color: Colors.white, size: 18),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: hitBoxPadding - 24,
                  left: hitBoxPadding - 24,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: widget.onEdit,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                          color: Colors.blueAccent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.edit, color: Colors.white, size: 18),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: hitBoxPadding - 24,
                  right: hitBoxPadding - 24,
                  child: GestureDetector(
                    // Expand the hit test area so the gesture is caught within the padding
                    behavior: HitTestBehavior.opaque,
                    onPanDown: (_) {},
                    onPanStart: (_) {},
                    onPanUpdate: _onResizeUpdate,
                    onPanEnd: _onResizeEnd,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                          color: Colors.blueAccent,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.open_in_full, color: Colors.white, size: 18),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
    );
  }
}
