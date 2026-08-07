import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../providers/app_state.dart';
import 'package:gal/gal.dart';

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
  final void Function(int sourcePageIndex, int docIndex, ScannedDocument doc, double dx, double dy) onCrossPageMove;
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
    required this.onCrossPageMove,
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
      double newWidth = width + details.delta.dx / widget.canvasScale;
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

  void _onPanStart(DragStartDetails details) {
    if (widget.onDragStarted != null) {
      widget.onDragStarted!();
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() {
      dx += details.delta.dx / widget.canvasScale;
      dy += details.delta.dy / widget.canvasScale;

      // Clamp horizontally
      dx = dx.clamp(0.0, widget.canvasWidth - width);
    });
  }

  void _onPanEnd(DragEndDetails details) {
    // Check if we need to do cross-page move
    if (dy < 0 || dy > widget.canvasHeight) {
      widget.onCrossPageMove(widget.pageIndex, widget.docIndex, widget.document, dx, dy);
    } else {
      widget.onLayoutUpdate(widget.pageIndex, widget.docIndex, dx, dy, width, height);
    }
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
                  Tooltip(
                    message: 'تغيير الحجم',
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanDown: (_) {},
                      onPanStart: (_) {},
                      onPanUpdate: _onResizeUpdate,
                      onPanEnd: _onResizeEnd,
                      child: const Padding(
                        padding: EdgeInsets.all(10),
                        child: Icon(Icons.open_in_full, size: 20, color: Colors.blueAccent),
                      ),
                    ),
                  ),
                  Tooltip(
                    message: 'تعديل',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () {
                          HapticFeedback.lightImpact();
                          widget.onEdit();
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(Icons.edit, size: 20, color: Colors.blueAccent),
                        ),
                      ),
                    ),
                  ),
                  Tooltip(
                    message: 'حفظ',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () {
                          HapticFeedback.lightImpact();
                          _saveToGallery();
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(Icons.save_alt, size: 20, color: Colors.green),
                        ),
                      ),
                    ),
                  ),
                  Tooltip(
                    message: 'حذف',
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: () {
                          HapticFeedback.lightImpact();
                          widget.onDelete();
                        },
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(Icons.close, size: 20, color: Colors.redAccent),
                        ),
                      ),
                    ),
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
      child: RepaintBoundary(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: documentWidget,
        ),
      ),
    );
  }
}
