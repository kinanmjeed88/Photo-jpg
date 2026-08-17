import 'dart:io';

import 'package:doc_scanner_app/providers/app_state.dart';
import 'package:doc_scanner_app/services/scanner_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DetectionPlan', () {
    test('allDocuments keeps independent housing and card detector passes', () {
      final plan = DetectionPlan.forType(DocumentType.allDocuments);

      expect(
        plan.types,
        containsAll(<DocumentType>[
          DocumentType.housingCard,
          DocumentType.nationalId,
          DocumentType.rationCard,
        ]),
      );
      expect(plan.contains(DocumentType.passport), isFalse);
      expect(plan.isA4Only, isFalse);
    });

    test(
      'passport remains a passport-only plan without preemption side effects',
      () {
        final plan = DetectionPlan.forType(DocumentType.passport);

        expect(plan.types, <DocumentType>[DocumentType.passport]);
        expect(plan.typeIndices, <int>[DocumentType.passport.index]);
      },
    );

    test('A4 remains a single full-frame plan', () {
      final plan = DetectionPlan.forType(DocumentType.a4Document);

      expect(plan.types, <DocumentType>[DocumentType.a4Document]);
      expect(plan.isA4Only, isTrue);
    });

    test('mixed housing and passport selection keeps both detector passes', () {
      final plan = DetectionPlan.forTypes(<DocumentType>[
        DocumentType.housingCard,
        DocumentType.passport,
      ]);

      expect(plan.types, <DocumentType>[
        DocumentType.housingCard,
        DocumentType.passport,
      ]);
      expect(plan.contains(DocumentType.housingCard), isTrue);
      expect(plan.contains(DocumentType.passport), isTrue);
      expect(plan.isA4Only, isFalse);
    });
  });

  group('DocumentRegion scaling', () {
    test(
      'scales review coordinates to source dimensions and clamps bounds',
      () {
        const region = DocumentRegion(
          left: -10,
          top: 20,
          right: 900,
          bottom: 700,
          area: 0,
        );

        final scaled = scaleDocumentRegionToSource(
          region,
          analysisWidth: 800,
          analysisHeight: 600,
          sourceWidth: 4000,
          sourceHeight: 3000,
        );

        expect(scaled.left, 0);
        expect(scaled.top, 100);
        expect(scaled.right, 4000);
        expect(scaled.bottom, 3000);
        expect(scaled.area, 11600000);
      },
    );

    test(
      'scaling keeps a valid region proportional for non-uniform dimensions',
      () {
        const region = DocumentRegion(
          left: 100,
          top: 50,
          right: 700,
          bottom: 550,
          area: 300000,
        );

        final scaled = scaleDocumentRegionToSource(
          region,
          analysisWidth: 800,
          analysisHeight: 600,
          sourceWidth: 1600,
          sourceHeight: 1200,
        );

        expect(scaled.left, 200);
        expect(scaled.top, 100);
        expect(scaled.right, 1400);
        expect(scaled.bottom, 1100);
        expect(scaled.area, 1200000);
      },
    );
  });

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

  test('A4 smart processing keeps one complete source image', () async {
    final directory = await Directory.systemTemp.createTemp('a4_smart_scan_');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/source.jpg');
    await source.writeAsBytes(<int>[1, 2, 3]);

    final result = await ScannerService().processSmartRecognition(
      source,
      documentType: DocumentType.a4Document,
    );

    expect(result.status, SmartScanStatus.succeeded);
    expect(result.files, hasLength(1));
    expect(result.files.single.path, source.path);
    expect(result.classification.type, DocumentType.a4Document);
    expect(result.classification.requiresManualReview, isFalse);
    expect(result.cropConfidence, 1);
    expect(result.detectedDocumentCount, 1);
    expect(result.requiresManualFallback, isFalse);
  });

  test(
    'A4 processing requests manual review when the source is missing',
    () async {
      final source = File(
        '${Directory.systemTemp.path}/missing_a4_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );

      final result = await ScannerService().processSmartRecognition(
        source,
        documentType: DocumentType.a4Document,
      );

      expect(result.status, SmartScanStatus.manualReviewRequired);
      expect(result.files, isEmpty);
      expect(result.classification.type, DocumentType.unknown);
    },
  );

  test(
    'low-confidence region triggers partial review without discarding accepted crops',
    () {
      final result = SmartScanResult(
        source: File('/tmp/source.jpg'),
        files: <File>[File('/tmp/cropped.jpg')],
        classification: const DocumentClassification(
          type: DocumentType.housingCard,
          normalizedText: '',
          confidence: 1,
          reason: 'Requested type',
          requiresManualReview: false,
        ),
        status: SmartScanStatus.manualReviewRequired,
        message: 'Boundary review required',
        cropConfidence: 0.54,
        detectedDocumentCount: 2,
        cropReviewReason: 'Boundary support is insufficient',
        manualReviewRegions: <DocumentRegion>[
          DocumentRegion(
            left: 10,
            top: 20,
            right: 210,
            bottom: 120,
            area: 20000,
          ),
        ],
      );

      expect(result.requiresManualFallback, isFalse);
      expect(result.requiresCropReview, isTrue);
      expect(result.manualReviewRegions, hasLength(1));
      expect(result.classification.requiresManualReview, isFalse);
      expect(result.cropReviewReason, isNotEmpty);
    },
  );

  test('an empty result still requires full manual fallback', () {
    final result = SmartScanResult(
      source: File('/tmp/source.jpg'),
      files: const <File>[],
      classification: DocumentClassification.unknown,
      status: SmartScanStatus.manualReviewRequired,
      message: 'No safe crop',
    );

    expect(result.requiresManualFallback, isTrue);
    expect(result.requiresCropReview, isFalse);
  });

  test(
    'empty accepted output with review regions stays a partial manual review',
    () {
      final result = SmartScanResult(
        source: File('/tmp/source.jpg'),
        files: const <File>[],
        classification: const DocumentClassification(
          type: DocumentType.nationalId,
          normalizedText: '',
          confidence: 0,
          reason: 'Boundary proposals need review',
          requiresManualReview: false,
        ),
        status: SmartScanStatus.manualReviewRequired,
        message: 'Review proposed boundaries',
        detectedDocumentCount: 5,
        manualReviewRegions: <DocumentRegion>[
          DocumentRegion(
            left: 10,
            top: 20,
            right: 210,
            bottom: 120,
            area: 20000,
            reason: 'حدود تحتاج إلى تأكيد',
          ),
        ],
      );

      expect(result.requiresManualFallback, isFalse);
      expect(result.requiresCropReview, isTrue);
      expect(result.manualReviewRegions, hasLength(1));
    },
  );

  test(
    'A successful high-confidence crop does not require manual fallback',
    () {
      final result = SmartScanResult(
        source: File('/tmp/source.jpg'),
        files: <File>[File('/tmp/cropped.jpg')],
        classification: const DocumentClassification(
          type: DocumentType.passport,
          normalizedText: '',
          confidence: 1,
          reason: 'Requested type',
          requiresManualReview: false,
        ),
        status: SmartScanStatus.succeeded,
        message: 'Success',
        cropConfidence: 0.91,
        detectedDocumentCount: 1,
      );

      expect(result.requiresManualFallback, isFalse);
    },
  );

  test('performance metrics remain safe and structured', () {
    const metrics = ScanPerformanceMetrics(
      stageMilliseconds: <String, int>{'decode': 12, 'detection': 34},
      peakMemoryBytes: 1024,
    );
    final result = SmartScanResult(
      source: File('/tmp/source.jpg'),
      files: <File>[File('/tmp/cropped.jpg')],
      classification: DocumentClassification.unknown,
      status: SmartScanStatus.succeeded,
      message: 'Success',
      performanceMetrics: metrics,
    );

    expect(result.performanceMetrics.stageMilliseconds['decode'], 12);
    expect(result.performanceMetrics.stageMilliseconds['detection'], 34);
    expect(result.performanceMetrics.peakMemoryBytes, 1024);
    expect(result.performanceMetrics.isEmpty, isFalse);
  });

  test('review region preserves a diagnostic reason', () {
    const region = DocumentRegion(
      left: 1,
      top: 2,
      right: 101,
      bottom: 202,
      area: 20000,
      reason: 'حدود المستند ضعيفة',
    );

    expect(region.reason, 'حدود المستند ضعيفة');
    expect(region.width, 100);
    expect(region.height, 200);
  });

  test('A4 batch processing returns one complete source per input', () async {
    final directory = await Directory.systemTemp.createTemp('a4_batch_scan_');
    addTearDown(() => directory.delete(recursive: true));
    final first = File('${directory.path}/first.jpg');
    final second = File('${directory.path}/second.jpg');
    await first.writeAsBytes(<int>[1]);
    await second.writeAsBytes(<int>[2]);
    var progressCalls = 0;

    final result = await ScannerService().processBatchSmartRecognition(
      <File>[first, second],
      documentType: DocumentType.a4Document,
      onProgress: (current, total) => progressCalls++,
    );

    expect(result.wasCancelled, isFalse);
    expect(result.results, hasLength(2));
    expect(progressCalls, 2);
    for (final source in <File>[first, second]) {
      final scan = result.results[source]!;
      expect(scan.status, SmartScanStatus.succeeded);
      expect(scan.files, hasLength(1));
      expect(scan.files.single.path, source.path);
      expect(scan.classification.type, DocumentType.a4Document);
    }
  });
}
