import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path_provider/path_provider.dart';
import 'dart:math' as math;

class CropRect {
  double left, top, width, height;
  CropRect(this.left, this.top, this.width, this.height);
}

Future<List<File>> _runMultiCropIsolate(Map<String, dynamic> args) {
  return Isolate.run(() => _processMultiCrop(args));
}

List<File> _processMultiCrop(Map<String, dynamic> args) {
  final String imagePath = args['imagePath'];
  final List<Map<String, double>> rects = (args['rects'] as List).cast<Map<String, double>>();
  final String tempPath = args['tempPath'];

  cv.Mat? src;
  List<File> croppedFiles = [];

  try {
    src = cv.imread(imagePath, flags: cv.IMREAD_COLOR);
    if (src.isEmpty) return [];

    double imageArea = (src.rows * src.cols).toDouble();

    for (int i = 0; i < rects.length; i++) {
      final rect = rects[i];
      int l = rect['left']!.toInt();
      int t = rect['top']!.toInt();
      int w = rect['width']!.toInt();
      int h = rect['height']!.toInt();

      l = math.max(0, l);
      t = math.max(0, t);
      if (l + w > src.cols) w = src.cols - l;
      if (t + h > src.rows) h = src.rows - t;

      if (w <= 0 || h <= 0) continue;

      cv.Mat cropped = src.region(cv.Rect(l, t, w, h));

      double cropArea = (w * h).toDouble();
      double aspect = w / h;

      bool isA4 = cropArea > (imageArea * 0.6) || (aspect >= 0.67 && aspect <= 0.75) || (aspect >= 1.35 && aspect <= 1.48); // A4 portrait ~0.71, landscape ~1.41

      String suffix = isA4 ? '_A4' : '_ID';
      String path = '$tempPath/manual_crop_${DateTime.now().millisecondsSinceEpoch}_$i$suffix.jpg';

      cv.imwrite(path, cropped);
      croppedFiles.add(File(path));
      cropped.dispose();
    }
  } catch (e) {
    print('Multi crop OpenCV failed: $e');
  } finally {
    src?.dispose();
  }

  return croppedFiles;
}

class MultiCropScreen extends StatefulWidget {
  final File imageFile;

  const MultiCropScreen({super.key, required this.imageFile});

  @override
  State<MultiCropScreen> createState() => _MultiCropScreenState();
}

class _MultiCropScreenState extends State<MultiCropScreen> {
  final List<CropRect> _cropRects = [];
  bool _isProcessing = false;
  ImageProvider? _imageProvider;
  Size? _imageSize;
  final GlobalKey _imageKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _imageProvider = FileImage(widget.imageFile);
    _loadImageSize();
  }

  Future<void> _loadImageSize() async {
    final decodedImage = await decodeImageFromList(await widget.imageFile.readAsBytes());
    setState(() {
      _imageSize = Size(decodedImage.width.toDouble(), decodedImage.height.toDouble());
    });
  }

  void _addCropBox() {
    if (_cropRects.length >= 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الحد الأقصى هو 5 مربعات قص')),
      );
      return;
    }
    setState(() {
      // Default to center 200x200
      _cropRects.add(CropRect(50, 50, 200, 200));
    });
  }

  void _removeCropBox(int index) {
    setState(() {
      _cropRects.removeAt(index);
    });
  }

  Future<void> _finishCropping() async {
    if (_cropRects.isEmpty) {
      Navigator.pop(context, <File>[widget.imageFile]); // fallback to raw
      return;
    }

    setState(() => _isProcessing = true);

    try {
      final RenderBox? imageBox = _imageKey.currentContext?.findRenderObject() as RenderBox?;
      if (imageBox == null || _imageSize == null) {
        throw Exception("Could not determine image layout.");
      }

      final widgetSize = imageBox.size;
      final double scaleX = _imageSize!.width / widgetSize.width;
      final double scaleY = _imageSize!.height / widgetSize.height;

      final tempDir = await getTemporaryDirectory();

      final mappedRects = _cropRects.map((rect) {
        return {
          'left': rect.left * scaleX,
          'top': rect.top * scaleY,
          'width': rect.width * scaleX,
          'height': rect.height * scaleY,
        };
      }).toList();

      final args = {
        'imagePath': widget.imageFile.path,
        'rects': mappedRects,
        'tempPath': tempDir.path,
      };

      final croppedFiles = await _runMultiCropIsolate(args);

      if (mounted) {
        Navigator.pop(context, croppedFiles.isEmpty ? [widget.imageFile] : croppedFiles);
      }
    } catch (e) {
      print("Manual crop failed: $e");
      if (mounted) {
        Navigator.pop(context, [widget.imageFile]);
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تحديد متعدد للمستندات'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: _isProcessing ? null : _finishCropping,
          )
        ],
      ),
      body: _isProcessing
        ? const Center(child: CircularProgressIndicator())
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Text('حدد إطارات حول المستندات. يمكنك إضافة حتى 5 إطارات.',
                  style: Theme.of(context).textTheme.titleMedium),
              ),
              Expanded(
                child: InteractiveViewer(
                  maxScale: 5.0,
                  child: Center(
                    child: Stack(
                      key: _imageKey,
                      children: [
                        if (_imageProvider != null)
                          Image(image: _imageProvider!, fit: BoxFit.contain),
                        ..._cropRects.asMap().entries.map((entry) {
                          final idx = entry.key;
                          final rect = entry.value;
                          return Positioned(
                            left: rect.left,
                            top: rect.top,
                            child: GestureDetector(
                              onPanUpdate: (details) {
                                setState(() {
                                  rect.left += details.delta.dx;
                                  rect.top += details.delta.dy;
                                });
                              },
                              child: Container(
                                width: rect.width,
                                height: rect.height,
                                decoration: BoxDecoration(
                                  border: Border.all(color: Colors.redAccent, width: 2),
                                  color: Colors.redAccent.withOpacity(0.1),
                                ),
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    Positioned(
                                      top: -30,
                                      right: -30,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onTap: () => _removeCropBox(idx),
                                        child: Container(
                                          width: 60,
                                          height: 60,
                                          color: Colors.transparent,
                                          child: const Center(
                                            child: CircleAvatar(
                                              radius: 12,
                                              backgroundColor: Colors.red,
                                              child: Icon(Icons.close, size: 16, color: Colors.white),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      bottom: -30,
                                      right: -30,
                                      child: GestureDetector(
                                        behavior: HitTestBehavior.opaque,
                                        onPanUpdate: (details) {
                                          setState(() {
                                            rect.width = math.max(10, rect.width + details.delta.dx);
                                            rect.height = math.max(10, rect.height + details.delta.dy);
                                          });
                                        },
                                        child: Container(
                                          width: 60,
                                          height: 60,
                                          color: Colors.transparent,
                                          child: const Center(
                                            child: CircleAvatar(
                                              radius: 12,
                                              backgroundColor: Colors.blue,
                                              child: Icon(Icons.open_in_full, size: 16, color: Colors.white),
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
                        }).toList(),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: ElevatedButton.icon(
                  onPressed: _addCropBox,
                  icon: const Icon(Icons.add_box),
                  label: const Text('إضافة إطار قص'),
                ),
              )
            ],
          ),
    );
  }
}
