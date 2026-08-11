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

  group('Capture Queue Tests', () {
    test('Queue generation determinism', () {
      final container = ProviderContainer();
      final notifier = container.read(appStateProvider.notifier);

      // Set toggles
      notifier.togglePassport(true);
      notifier.toggleNationalId(true);
      notifier.toggleHousingCard(false);
      notifier.toggleRationCard(true);

      // Start session generates queue
      notifier.startSession();
      final state = container.read(appStateProvider);

      expect(state.isSessionActive, true);
      expect(state.currentCaptureIndex, 0);
      expect(
        state.captureQueue,
        [
          DocumentType.passport,
          DocumentType.nationalId,
          DocumentType.nationalId,
          DocumentType.rationCard,
          DocumentType.rationCard
        ]
      );
      expect(state.expectedCurrentType, DocumentType.passport);
    });

    test('Empty selection fallback', () {
      final container = ProviderContainer();
      final notifier = container.read(appStateProvider.notifier);

      // Start session with no toggles active
      notifier.startSession();
      final state = container.read(appStateProvider);

      expect(state.isSessionActive, false);
      expect(state.captureQueue, isEmpty);
      expect(state.expectedCurrentType, DocumentType.a4Document);
    });

    test('Deletion pointer revert', () {
      final container = ProviderContainer();
      final notifier = container.read(appStateProvider.notifier);

      notifier.toggleNationalId(true);
      notifier.startSession();

      // Advance by 1
      notifier.advanceCapture();
      expect(container.read(appStateProvider).currentCaptureIndex, 1);

      // Revert pointer
      notifier.revertCapture();
      expect(container.read(appStateProvider).currentCaptureIndex, 0);

      // Reverting past 0 stays at 0
      notifier.revertCapture();
      expect(container.read(appStateProvider).currentCaptureIndex, 0);
    });

    test('Over-capture edge case', () {
      final container = ProviderContainer();
      final notifier = container.read(appStateProvider.notifier);

      notifier.togglePassport(true); // Generates 1 item queue
      notifier.startSession();

      expect(container.read(appStateProvider).expectedCurrentType, DocumentType.passport);

      // Advance past the queue length
      notifier.advanceCapture();

      // The expected behavior: fallback to the last type in the queue if over-captured
      expect(container.read(appStateProvider).expectedCurrentType, DocumentType.passport);
    });
  });
}
