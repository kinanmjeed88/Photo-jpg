import re

with open('lib/screens/image_editor_screen.dart', 'r') as f:
    content = f.read()

# I need to add _runPreviewIsolate top-level function

preview_isolate_code = """
Future<Uint8List> _runPreviewIsolate(Map<String, dynamic> args) async {
  final Uint8List bytes = args['bytes'];
  final double sharpness = args['sharpness'];

  cv.Mat? src;
  cv.Mat? sharpened;
  try {
    src = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (src.isEmpty) return bytes;

    if (sharpness > 0) {
      final blurred = cv.gaussianBlur(src, (0, 0), sharpness);
      sharpened = cv.addWeighted(src, 1.5, blurred, -0.5, 0);
      blurred.dispose();
      src.dispose();
      src = sharpened;
    }

    // Scale down image slightly for live preview to ensure it's fast (<100ms latency target)
    // Actually, only encode to JPG.
    final (_, encodedBytes) = cv.imencode('.jpg', src);
    return encodedBytes;
  } catch (e) {
    print('OpenCV Preview Isolate failed: $e');
    return bytes;
  } finally {
    src?.dispose();
  }
}

String _processEditedImage(Map<String, dynamic> args) {
"""

content = content.replace("String _processEditedImage(Map<String, dynamic> args) {", preview_isolate_code)

with open('lib/screens/image_editor_screen.dart', 'w') as f:
    f.write(content)
