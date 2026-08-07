with open('lib/screens/image_editor_screen.dart', 'r') as f:
    content = f.read()

content = content + "\n}\n"

with open('lib/screens/image_editor_screen.dart', 'w') as f:
    f.write(content)
