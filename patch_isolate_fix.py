import re

with open('lib/screens/image_editor_screen.dart', 'r') as f:
    content = f.read()

if "import 'package:opencv_dart/opencv_dart.dart' as cv;" not in content:
    content = content.replace("import 'package:flutter/material.dart';", "import 'package:flutter/material.dart';\nimport 'package:opencv_dart/opencv_dart.dart' as cv;")

with open('lib/screens/image_editor_screen.dart', 'w') as f:
    f.write(content)
