import 'dart:io';

abstract class DocumentDetectionProvider {
  /// Extracts cropped document images from the given image [file].
  ///
  /// The [requestId] uniquely identifies the current scan operation. Any subsequent
  /// scan operation with a different [requestId] should cancel the previous one.
  Future<List<File>> extractDocuments(String requestId, File file);
}
