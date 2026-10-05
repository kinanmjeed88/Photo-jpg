import 'dart:io';

import 'package:doc_scanner_app/providers/app_state.dart';
import 'package:doc_scanner_app/services/scanner_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A smart-scan result carries one document type *per crop*.
///
/// The multi-crop flow used to stamp the single source-level classification on
/// every crop, so a page holding a national ID and a housing card produced two
/// documents with the same type. These tests pin the per-crop contract,
/// including the explicit `unknown` path: an uncertain detector result must
/// never be replaced by a guess.
void main() {
  SmartScanResult resultWith({
    required List<String> paths,
    required List<DocumentType> outputTypes,
    DocumentType classificationType = DocumentType.unknown,
  }) {
    return SmartScanResult(
      source: File('/tmp/source.jpg'),
      files: paths.map(File.new).toList(growable: false),
      outputTypes: outputTypes,
      classification: DocumentClassification(
        type: classificationType,
        normalizedText: '',
        confidence: classificationType == DocumentType.unknown ? 0 : 0.8,
        reason: 'test',
        requiresManualReview: classificationType == DocumentType.unknown,
      ),
      status: SmartScanStatus.succeeded,
      message: '',
    );
  }

  test('each crop keeps its own detector type', () {
    final result = resultWith(
      paths: <String>['/tmp/crop-0.jpg', '/tmp/crop-1.jpg'],
      outputTypes: <DocumentType>[
        DocumentType.nationalId,
        DocumentType.housingCard,
      ],
      classificationType: DocumentType.allDocuments,
    );

    expect(
      result.typeFor(File('/tmp/crop-0.jpg')),
      DocumentType.nationalId,
    );
    expect(
      result.typeFor(File('/tmp/crop-1.jpg')),
      DocumentType.housingCard,
    );
  });

  test(
    'a crop without its own type falls back to the source classification',
    () {
      final result = resultWith(
        paths: <String>['/tmp/crop-0.jpg', '/tmp/crop-1.jpg'],
        outputTypes: const <DocumentType>[],
        classificationType: DocumentType.passport,
      );

      expect(result.typeFor(File('/tmp/crop-0.jpg')), DocumentType.passport);
      expect(result.typeFor(File('/tmp/crop-1.jpg')), DocumentType.passport);
    },
  );

  test('an unknown detector result is not replaced by a guess', () {
    final result = resultWith(
      paths: <String>['/tmp/crop-0.jpg'],
      outputTypes: const <DocumentType>[DocumentType.unknown],
      classificationType: DocumentType.unknown,
    );

    expect(result.typeFor(File('/tmp/crop-0.jpg')), DocumentType.unknown);
  });

  test('a file that is not part of the result reports the classification', () {
    final result = resultWith(
      paths: <String>['/tmp/crop-0.jpg'],
      outputTypes: const <DocumentType>[DocumentType.rationCard],
      classificationType: DocumentType.nationalId,
    );

    expect(result.typeFor(File('/tmp/other.jpg')), DocumentType.nationalId);
  });

  test('the constructor stays usable without per-crop types', () {
    final result = SmartScanResult(
      source: File('/tmp/source.jpg'),
      files: <File>[File('/tmp/crop-0.jpg')],
      classification: const DocumentClassification(
        type: DocumentType.a4Document,
        normalizedText: '',
        confidence: 1,
        reason: 'requested type',
        requiresManualReview: false,
      ),
      status: SmartScanStatus.succeeded,
      message: '',
    );

    expect(result.outputTypes, isEmpty);
    expect(result.typeFor(File('/tmp/crop-0.jpg')), DocumentType.a4Document);
  });
}
