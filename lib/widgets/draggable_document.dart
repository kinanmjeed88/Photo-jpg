import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final VoidCallback? onDragStarted;

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

  @override
  Widget build(BuildContext context) {
    debugPrint('isSelected: ${widget.isSelected}, isDragging: $isDragging');

    Widget documentWidget = SizedBox(
      width: width,
      height: height,
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
          ],
        ),
      ),
    );
  }
}
