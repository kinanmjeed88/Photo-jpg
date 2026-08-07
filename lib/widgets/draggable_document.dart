import 'package:flutter/material.dart';
import '../providers/app_state.dart';
import 'package:gal/gal.dart'; // Ensure gal is used for saving if needed, but we probably just use existing logic or add a callback.

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

      final double toolbarHeight = widget.isSelected ? 40.0 : 0.0;

      if (newWidth > widget.canvasWidth - dx) {
        newWidth = widget.canvasWidth - dx;
        newHeight = newWidth / _documentAspectRatio;
      }

      if (newHeight + toolbarHeight > widget.canvasHeight - dy) {
        newHeight = widget.canvasHeight - dy - toolbarHeight;
        newWidth = newHeight * _documentAspectRatio;
      }

      width = newWidth;
      height = newHeight;
    });
  }

  void _onResizeEnd(DragEndDetails details) {
    widget.onLayoutUpdate(widget.pageIndex, widget.docIndex, dx, dy, width, height);
  }

  Offset _customDragAnchorStrategy(Draggable<Object> draggable, BuildContext context, Offset position) {
    final RenderBox renderObject = context.findRenderObject()! as RenderBox;
    final Offset globalTopLeft = renderObject.localToGlobal(Offset.zero);
    return position - globalTopLeft;
  }

  Future<void> _saveToGallery() async {
      try {
        await Gal.putImage(widget.document.file.path);
        if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم الحفظ في المعرض')));
        }
      } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ في الحفظ: $e')));
          }
      }
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

    final double toolbarHeight = 40.0;
    final double totalHeight = height + (widget.isSelected ? toolbarHeight : 0);

    Widget documentWidget = SizedBox(
      width: width,
      height: totalHeight,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
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
                child: Image.file(widget.document.file, fit: BoxFit.contain),
              ),
            ),
          ),
          if (widget.isSelected)
            Container(
              width: width,
              height: toolbarHeight,
              color: Colors.grey[200],
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  GestureDetector(
                    onPanUpdate: _onResizeUpdate,
                    onPanEnd: _onResizeEnd,
                    child: const Icon(Icons.open_in_full, size: 20, color: Colors.blueAccent),
                  ),
                  IconButton(
                    icon: const Icon(Icons.edit, size: 20, color: Colors.blueAccent),
                    onPressed: widget.onEdit,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.save_alt, size: 20, color: Colors.green),
                    onPressed: _saveToGallery,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20, color: Colors.redAccent),
                    onPressed: widget.onDelete,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
        ],
      ),
    );

    return Positioned(
      left: dx,
      top: dy,
      child: Draggable<Map<String, dynamic>>(
        dragAnchorStrategy: _customDragAnchorStrategy,
        onDragStarted: widget.onDragStarted,
        data: dragData,
        feedback: Material(
          color: Colors.transparent,
          child: SizedBox(
            width: width * widget.canvasScale,
            height: totalHeight * widget.canvasScale,
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: width,
                height: totalHeight,
                child: documentWidget,
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.3,
          child: documentWidget,
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.onTap,
          child: documentWidget,
        ),
      ),
    );
  }
}
