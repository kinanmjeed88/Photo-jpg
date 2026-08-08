import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:doc_scanner_app/providers/app_state.dart';

// Create a mock image file that can be decoded by decodeImageFromList
Future<File> createMockImageFile(String path) async {
  // A simple valid 1x1 GIF
  final Uint8List gifBytes = Uint8List.fromList([
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00,
    0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x21, 0xf9, 0x04, 0x01, 0x0a, 0x00, 0x01,
    0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02,
    0x4c, 0x01, 0x00, 0x3b
  ]);
  final file = File(path);
  await file.writeAsBytes(gifBytes);
  return file;
}

Future<File> createCorruptedImageFile(String path) async {
  final file = File(path);
  await file.writeAsBytes([0x00, 0x01, 0x02, 0x03]); // Invalid image data
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScannedDocumentsNotifier - batchAddDocuments', () {
    late ProviderContainer container;
    late AppState appState;

    setUp(() {
      container = ProviderContainer();
      appState = AppState();
    });

    tearDown(() {
      container.dispose();
    });

    test('Empty list returns empty BatchAddResult', () async {
      final notifier = container.read(scannedDocumentsProvider.notifier);
      final result = await notifier.batchAddDocuments([], appState, 0);

      expect(result.addedDocuments, isEmpty);
      expect(result.overflowFiles, isEmpty);
      expect(result.failedFiles, isEmpty);
      expect(container.read(scannedDocumentsProvider), isEmpty);
    });

    test('All files fail decoding returns failedFiles list', () async {
      final badFile1 = await createCorruptedImageFile('bad1.jpg');
      final badFile2 = await createCorruptedImageFile('bad2.jpg');

      final notifier = container.read(scannedDocumentsProvider.notifier);
      final result = await notifier.batchAddDocuments([badFile1, badFile2], appState, 0);

      expect(result.addedDocuments, isEmpty);
      expect(result.overflowFiles, isEmpty);
      expect(result.failedFiles.length, 2);

      // Need to compare file path because objects might be different
      expect(result.failedFiles.map((f) => f.path), contains(badFile1.path));
      expect(result.failedFiles.map((f) => f.path), contains(badFile2.path));
      expect(container.read(scannedDocumentsProvider), isEmpty);

      await badFile1.delete();
      await badFile2.delete();
    });

    test('State updates correctly after successful batch', () async {
      final goodFile1 = await createMockImageFile('good1.jpg');
      final goodFile2 = await createMockImageFile('good2.jpg');

      final notifier = container.read(scannedDocumentsProvider.notifier);
      final result = await notifier.batchAddDocuments([goodFile1, goodFile2], appState, 0);

      expect(result.addedDocuments.length, 2);
      expect(result.overflowFiles, isEmpty);
      expect(result.failedFiles, isEmpty);

      final state = container.read(scannedDocumentsProvider);
      expect(state.containsKey(0), isTrue);
      expect(state[0]?.length, 2);
      expect(state[0]?[0].file.path, 'good1.jpg');
      expect(state[0]?[1].file.path, 'good2.jpg');

      await goodFile1.delete();
      await goodFile2.delete();
    });
  });
}
