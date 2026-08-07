import re

with open('lib/widgets/draggable_document.dart', 'r') as f:
    content = f.read()

# Replace _documentAspectRatio getter with a simple calculation
replace_aspect_ratio = """
  double get _documentAspectRatio {
    if (height > 0) {
      return width / height;
    }
    return 1.0;
  }
"""
pattern = re.compile(r"  double get _documentAspectRatio \{.*?    \}[\n\r]*  \}", re.DOTALL)
content = pattern.sub(replace_aspect_ratio, content)

# Change Image.file fit to contain just in case, but keep the aspect ratio
content = content.replace("Image.file(widget.document.file, fit: BoxFit.fill)", "Image.file(widget.document.file, fit: BoxFit.contain)")

with open('lib/widgets/draggable_document.dart', 'w') as f:
    f.write(content)
