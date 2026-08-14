import 'dart:io';

import 'package:doc_scanner_app/services/scanner_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ScanCancellationToken', () {
    test('notifies listeners once and remains idempotent', () {
      final token = ScanCancellationToken();
      var notifications = 0;
      void listener() => notifications++;

      token.addListener(listener);
      token.cancel();
      token.cancel();

      expect(token.isCancelled, isTrue);
      expect(notifications, 1);
      expect(token.whenCancelled, completes);
    });

    test('notifies a listener added after cancellation immediately', () {
      final token = ScanCancellationToken()..cancel();
      var notified = false;

      token.addListener(() => notified = true);

      expect(notified, isTrue);
    });
  });

  test(
    'batch processing exits before starting any worker after cancellation',
    () async {
      final token = ScanCancellationToken()..cancel();
      var progressCalls = 0;

      final result = await ScannerService().processBatchSmartRecognition(
        <File>[File('/does/not/start.jpg')],
        cancellationToken: token,
        onProgress: (current, total) {
          progressCalls++;
        },
      );

      expect(result.wasCancelled, isTrue);
      expect(result.results, isEmpty);
      expect(progressCalls, 0);
    },
  );
}
