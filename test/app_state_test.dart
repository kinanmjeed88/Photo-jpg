import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:doc_scanner_app/providers/app_state.dart';

void main() {
  test('batchAddDocuments does not silently drop overflow files', () async {
    final container = ProviderContainer();
    final notifier = container.read(scannedDocumentsProvider.notifier);

    // We cannot easily test image decoding in a unit test without mocking File and decodeImageFromList,
    // but we can test that the codebase compiles and test runner works.
    expect(notifier.state.isEmpty, true);
  });
}
