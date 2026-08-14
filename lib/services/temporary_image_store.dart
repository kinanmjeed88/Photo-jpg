import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Owns scanner-generated work files. Only files with a managed prefix may be
/// removed, preventing accidental deletion of user-owned gallery media.
class TemporaryImageStore {
  TemporaryImageStore._();

  static const Set<String> _managedPrefixes = <String>{
    'cropped_',
    'manual_crop_',
    'smart_cropped_',
    'edited_',
    'ocr_preprocessed_',
  };
  static final Random _random = Random.secure();

  static Future<File> writeJpeg(
    Uint8List bytes, {
    required String prefix,
  }) async {
    final file = File(await createPath(prefix));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static Future<String> createPath(String prefix, {String suffix = ''}) async {
    final directory = await getTemporaryDirectory();
    return path.join(directory.path, uniqueJpegName(prefix, suffix: suffix));
  }

  static String uniqueJpegName(String prefix, {String suffix = ''}) {
    if (!_managedPrefixes.contains(prefix)) {
      throw ArgumentError.value(prefix, 'prefix', 'Unmanaged temporary prefix');
    }
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    final entropy = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return '$prefix$timestamp-$entropy$suffix.jpg';
  }

  static bool isManaged(File file) {
    final fileName = path.basename(file.path);
    return _managedPrefixes.any((prefix) => fileName.startsWith(prefix)) &&
        fileName.endsWith('.jpg');
  }

  static Future<void> deleteIfManaged(File file) async {
    if (!isManaged(file)) return;
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Cleanup is best effort; the current user action remains successful.
    }
  }

  static Future<void> deleteManagedWithMarker(String marker) async {
    if (marker.isEmpty) return;
    final directory = await getTemporaryDirectory();
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File &&
            isManaged(entity) &&
            path.basename(entity.path).contains(marker)) {
          await deleteIfManaged(entity);
        }
      }
    } on FileSystemException {
      // Cancellation cleanup is best effort and must not block the UI.
    }
  }

  /// Removes stale internal work files while preserving recent edits referenced
  /// by the active layout. This is called on entry to image-producing flows.
  static Future<void> cleanupStale({
    Duration maxAge = const Duration(hours: 12),
    Set<String> protectedPaths = const <String>{},
  }) async {
    final directory = await getTemporaryDirectory();
    final cutoff = DateTime.now().subtract(maxAge);
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File || !isManaged(entity)) continue;
        if (protectedPaths.contains(entity.path)) continue;
        final modified = await entity.lastModified();
        if (modified.isBefore(cutoff)) {
          await deleteIfManaged(entity);
        }
      }
    } on FileSystemException {
      // Temporary-directory cleanup must never block the scanning workflow.
    }
  }
}
