import 'dart:io';

void main() {
  var file = File('lib/services/scanner_service.dart');
  var content = file.readAsStringSync();

  // Find lines to remove
  var lines = content.split('\n');
  var newLines = <String>[];

  bool skip = false;
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (line.contains('orderedPts') && line.contains('.toList()') && i > 185 && i < 205) {
      skip = true;
      continue;
    }
    if (skip && line.trim() == ');') {
      skip = false;
      continue;
    }
    if (skip) {
      continue;
    }

    // Also the dstPts one
    if (line.contains('dstPts') && line.contains('.toList()') && i > 185 && i < 205) {
      skip = true;
      continue;
    }

    newLines.add(line);
  }

  file.writeAsStringSync(newLines.join('\n'));
}
