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
  final VoidCallback? onRecrop;
  final void Function(int pageIndex, int docIndex, double dx, double dy, double width, double height, int rotationAngle) onLayoutUpdate;
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
    this.onRecrop,
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
  late int rotationAngle;
  bool isDragging = false;

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

  void _onResizeUpdate(DragUpdateDetails details) {
    setState(() {
      double newWidth = width + details.delta.dx / widget.canvasScale;
      if (newWidth < 50) newWidth = 50;
      double newHeight = newWidth / _documentAspectRatio;

      final double toolbarHeight = widget.isSelected ? 48.0 : 0.0;

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
    widget.onLayoutUpdate(widget.pageIndex, widget.docIndex, dx, dy, width, height, rotationAngle);
  }

  void _onPanStart(DragStartDetails details) {
    setState(() {
      isDragging = true;
    });
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
    setState(() {
      isDragging = false;
    });
    // Check if we need to do cross-page move
    if (dy < 0 || dy > widget.canvasHeight) {
      widget.onCrossPageMove(widget.pageIndex, widget.docIndex, widget.document, dx, dy);
    } else {
      widget.onLayoutUpdate(widget.pageIndex, widget.docIndex, dx, dy, width, height, rotationAngle);
    }
  }

  void _onPanCancel() {
    setState(() {
      isDragging = false;
    });
  }

  void _onRotate() {
    HapticFeedback.lightImpact();
    setState(() {
      // Calculate center point
      double centerX = dx + width / 2;
      double centerY = dy + height / 2;

      // Swap width and height
      double newWidth = height;
      double newHeight = width;

      // Calculate new dx, dy to keep the center stable
      double newDx = centerX - newWidth / 2;
      double newDy = centerY - newHeight / 2;

      // Clamp to virtual A4 canvas bounds
      if (newDx < 0) newDx = 0;
      if (newDy < 0) newDy = 0;
      if (newDx + newWidth > widget.canvasWidth) newDx = widget.canvasWidth - newWidth;
      if (newDy + newHeight > widget.canvasHeight) newDy = widget.canvasHeight - newHeight;

      // Update state variables
      dx = newDx;
      dy = newDy;
      width = newWidth;
      height = newHeight;
      rotationAngle = (rotationAngle + 90) % 360;

      // Commit to parent
      widget.onLayoutUpdate(widget.pageIndex, widget.docIndex, dx, dy, width, height, rotationAngle);
    });
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
    debugPrint('isSelected: ${widget.isSelected}, isDragging: $isDragging');

    final double toolbarHeight = 48.0;
    final double totalHeight = height + (widget.isSelected ? toolbarHeight : 0);

    Widget documentWidget = SizedBox(
      width: width,
      height: totalHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: RepaintBoundary(
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
            ),
          ),
        ],
      ),
    );

    return Positioned(
      left: dx,
      top: dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        onPanCancel: _onPanCancel,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            documentWidget,
            AnimatedPositioned(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutBack,
              bottom: (widget.isSelected && !isDragging) ? -70 : -110, // DRAG-AWARE VISIBILITY
              left: 0,
              right: 0,
              height: 70, // Explicit height prevents layout collapse
              child: OverflowBox(
                maxWidth: double.infinity,
                maxHeight: 70,
                alignment: Alignment.center,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: (widget.isSelected && !isDragging) ? 1.0 : 0.0, // DRAG-AWARE VISIBILITY
                  child: Center(
                    child: _buildToolbarPill(),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbarPill() {
    return GestureDetector(
      onTap: () {},
      behavior: HitTestBehavior.opaque,
      child: Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(
                  Theme.of(context).brightness == Brightness.dark ? 0.5 : 0.18),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _toolbarButton(Icons.close, Colors.red, widget.onDelete, 'حذف'),
            _toolbarButton(Icons.download, Colors.green, _saveToGallery, 'حفظ'),
            _buildDivider(),
            _toolbarButton(Icons.edit, Colors.blue, widget.onEdit, 'تعديل'),
            _toolbarButton(Icons.crop, Colors.blue, widget.onRecrop, 'قص'),
            _buildDivider(),
            _toolbarButton(Icons.rotate_right, Colors.blue, _onRotate, 'تدوير'),
            _toolbarButton(Icons.open_in_full, Colors.blue, null, 'تكبير',
                onResizeUpdate: _onResizeUpdate, onResizeEnd: _onResizeEnd),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildDivider() {
    return Container(
      height: 24,
      width: 1,
      color: Colors.grey.withOpacity(0.3),
      margin: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _toolbarButton(IconData icon, Color color, VoidCallback? onTap, String tooltip, {Function(DragUpdateDetails)? onResizeUpdate, Function(DragEndDetails)? onResizeEnd}) {
    if (onResizeUpdate != null && onResizeEnd != null) {
        return Tooltip(
          message: tooltip,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanDown: (_) {},
            onPanStart: (_) {},
            onPanUpdate: onResizeUpdate,
            onPanEnd: onResizeEnd,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: Icon(icon, size: 20, color: color),
              ),
            ),
          ),
        );
    }
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () {
            if (onTap != null) {
              HapticFeedback.lightImpact();
              onTap();
            }
          },
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Icon(icon, size: 20, color: color),
            ),
          ),
        ),
      ),
    );
  }

}
