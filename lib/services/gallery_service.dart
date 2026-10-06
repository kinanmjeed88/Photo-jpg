import 'dart:io';
import 'dart:typed_data';

import 'package:gal/gal.dart';

/// Raised when a scan cannot be written to the device gallery.
///
/// [message] is ready to display: it is written in the UI language and explains
/// the actual cause instead of a generic failure.
class GallerySaveException implements Exception {
  const GallerySaveException(this.message);

  final String message;

  @override
  String toString() => 'GallerySaveException: $message';
}

/// The single entry point for saving scans into the system gallery.
///
/// Gallery access is owned by the `gal` plugin: on Android 13+ and on iOS it
/// requests the correct per-API permission (including the "add photos only"
/// level), which is why `permission_handler` is not used for this path anymore.
/// Every failure is translated into a specific, actionable Arabic message.
class GalleryService {
  const GalleryService._();

  /// Saves the image at [path] to the gallery.
  static Future<void> saveFile(File file) async {
    await _ensureAccess();
    try {
      await Gal.putImage(file.path);
    } on GallerySaveException {
      rethrow;
    } catch (error) {
      throw GallerySaveException(describe(error));
    }
  }

  /// Saves raw JPEG [bytes] to the gallery under [name].
  static Future<void> saveBytes(Uint8List bytes, {required String name}) async {
    await _ensureAccess();
    try {
      await Gal.putImageBytes(bytes, name: name);
    } on GallerySaveException {
      rethrow;
    } catch (error) {
      throw GallerySaveException(describe(error));
    }
  }

  static Future<void> _ensureAccess() async {
    try {
      if (await Gal.hasAccess()) return;
      if (await Gal.requestAccess()) return;
    } catch (error) {
      throw GallerySaveException(describe(error));
    }
    throw const GallerySaveException(
      'لم يُسمح بالوصول إلى المعرض لحفظ الصورة.',
    );
  }

  /// Maps a plugin error to a user-facing Arabic message.
  static String describe(Object error) {
    if (error is GallerySaveException) return error.message;
    if (error is GalException) {
      switch (error.type) {
        case GalExceptionType.accessDenied:
          return 'لم يُسمح بالوصول إلى المعرض لحفظ الصورة.';
        case GalExceptionType.notEnoughSpace:
          return 'لا توجد مساحة كافية لحفظ الصورة.';
        case GalExceptionType.notSupportedFormat:
          return 'صيغة الصورة غير مدعومة للحفظ في المعرض.';
        case GalExceptionType.unexpected:
          return 'تعذر حفظ الصورة في المعرض.';
      }
    }
    return 'تعذر حفظ الصورة في المعرض.';
  }
}
