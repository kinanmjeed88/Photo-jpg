import 'dart:io';
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path_provider/path_provider.dart';

import '../providers/app_state.dart';
import 'temporary_image_store.dart';

enum SmartScanStatus { succeeded, manualReviewRequired, failed, cancelled }

class ScanCancellationToken {
  bool _isCancelled = false;
  final Set<void Function()> _listeners = <void Function()>{};
  final Completer<void> _cancelled = Completer<void>.sync();

  bool get isCancelled => _isCancelled;
  Future<void> get whenCancelled => _cancelled.future;

  void addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}

class DocumentClassification {
  const DocumentClassification({
    required this.type,
    required this.normalizedText,
    required this.confidence,
    required this.reason,
    required this.requiresManualReview,
  });

  final DocumentType type;
  final String normalizedText;
  final double confidence;
  final String reason;
  final bool requiresManualReview;

  static const unknown = DocumentClassification(
    type: DocumentType.unknown,
    normalizedText: '',
    confidence: 0,
    reason: 'لم يُحسم نوع المستند تلقائياً.',
    requiresManualReview: true,
  );
}

class SmartScanResult {
  const SmartScanResult({
    required this.source,
    required this.files,
    required this.classification,
    required this.status,
    required this.message,
  });

  final File source;
  final List<File> files;
  final DocumentClassification classification;
  final SmartScanStatus status;
  final String message;

  bool get requiresManualFallback =>
      status == SmartScanStatus.manualReviewRequired ||
      status == SmartScanStatus.failed ||
      classification.requiresManualReview;
}

class SmartScanBatchResult {
  const SmartScanBatchResult({
    required this.results,
    required this.wasCancelled,
  });

  final Map<File, SmartScanResult> results;
  final bool wasCancelled;
}

/// A rectangular region proposed by the document detector.
///
/// This small value object keeps candidate de-duplication deterministic and
/// makes the multi-document selection rule testable without camera plugins.
class DocumentRegion {
  const DocumentRegion({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.area,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;
  final double area;

  double get width => math.max(0, right - left).toDouble();
  double get height => math.max(0, bottom - top).toDouble();
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  @override
  bool operator ==(Object other) =>
      other is DocumentRegion &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom &&
      other.area == area;

  @override
  int get hashCode => Object.hash(left, top, right, bottom, area);
}

List<DocumentRegion> selectDistinctDocumentRegions(
  Iterable<DocumentRegion> candidates,
) {
  final ordered = List<DocumentRegion>.of(candidates)
    ..sort((first, second) => second.area.compareTo(first.area));
  final selected = <DocumentRegion>[];
  for (final candidate in ordered) {
    if (selected.every(
      (accepted) => !_isDuplicateRegion(candidate, accepted),
    )) {
      selected.add(candidate);
    }
  }
  selected.sort((first, second) {
    final vertical = first.top.compareTo(second.top);
    return vertical != 0 ? vertical : first.left.compareTo(second.left);
  });
  return selected;
}

class _DocumentDetectionProfile {
  const _DocumentDetectionProfile({
    required this.type,
    required this.minimumLongToShortRatio,
    required this.maximumLongToShortRatio,
    required this.minimumAreaRatio,
    required this.maximumAreaRatio,
  });

  final DocumentType type;
  final double minimumLongToShortRatio;
  final double maximumLongToShortRatio;
  final double minimumAreaRatio;
  final double maximumAreaRatio;

  bool acceptsAspectRatio(double width, double height) {
    if (width <= 0 || height <= 0) return false;
    final ratio = math.max(width, height) / math.min(width, height);
    return ratio >= minimumLongToShortRatio && ratio <= maximumLongToShortRatio;
  }

  bool acceptsArea(double area, double imageArea) {
    if (imageArea <= 0) return false;
    final ratio = area / imageArea;
    return ratio >= minimumAreaRatio && ratio <= maximumAreaRatio;
  }
}

_DocumentDetectionProfile _detectionProfileFor(DocumentType type) {
  switch (type) {
    case DocumentType.passport:
      // The passport is commonly captured either portrait (~0.7 W/H) or
      // rotated landscape. The comparison is therefore orientation agnostic.
      return const _DocumentDetectionProfile(
        type: DocumentType.passport,
        minimumLongToShortRatio: 1.33,
        maximumLongToShortRatio: 1.55,
        minimumAreaRatio: 0.008,
        maximumAreaRatio: 0.96,
      );
    case DocumentType.nationalId:
    case DocumentType.housingCard:
    case DocumentType.rationCard:
      return _DocumentDetectionProfile(
        type: type,
        minimumLongToShortRatio: 1.4,
        maximumLongToShortRatio: 1.7,
        minimumAreaRatio: 0.008,
        maximumAreaRatio: 0.96,
      );
    case DocumentType.unknown:
      return const _DocumentDetectionProfile(
        type: DocumentType.unknown,
        minimumLongToShortRatio: 1.0,
        maximumLongToShortRatio: 3.5,
        minimumAreaRatio: 0.008,
        maximumAreaRatio: 0.96,
      );
    case DocumentType.a4Document:
      return const _DocumentDetectionProfile(
        type: DocumentType.a4Document,
        minimumLongToShortRatio: 1.0,
        maximumLongToShortRatio: 3.5,
        minimumAreaRatio: 0,
        maximumAreaRatio: 1,
      );
  }
}

DocumentType _documentTypeFromIndex(Object? value) {
  if (value is! int || value < 0 || value >= DocumentType.values.length) {
    return DocumentType.unknown;
  }
  return DocumentType.values[value];
}

class _DocumentCandidate {
  const _DocumentCandidate({
    required this.points,
    required this.area,
    required this.width,
    required this.height,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final List<cv.Point> points;
  final double area;
  final double width;
  final double height;
  final int left;
  final int top;
  final int right;
  final int bottom;

  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  DocumentRegion get region => DocumentRegion(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    area: area,
  );
}

List<cv.Point> _orderPoints(Iterable<cv.Point> points) {
  final byVerticalPosition = List<cv.Point>.from(points)
    ..sort((left, right) => left.y.compareTo(right.y));
  final top = byVerticalPosition.take(2).toList()
    ..sort((left, right) => left.x.compareTo(right.x));
  final bottom = byVerticalPosition.skip(2).take(2).toList()
    ..sort((left, right) => left.x.compareTo(right.x));
  return <cv.Point>[top[0], top[1], bottom[1], bottom[0]];
}

int _clampInt(int value, int lower, int upper) =>
    value.clamp(lower, upper).toInt();

double _distance(cv.Point first, cv.Point second) {
  final deltaX = first.x - second.x;
  final deltaY = first.y - second.y;
  return math.sqrt((deltaX * deltaX) + (deltaY * deltaY));
}

double _polygonArea(List<cv.Point> points) {
  var total = 0.0;
  for (var index = 0; index < points.length; index++) {
    final current = points[index];
    final next = points[(index + 1) % points.length];
    total += (current.x * next.y) - (next.x * current.y);
  }
  return total.abs() / 2;
}

_DocumentCandidate? _candidateFromContour(
  cv.VecPoint contour, {
  required double imageArea,
  required _DocumentDetectionProfile profile,
  bool allowAxisAlignedFallback = false,
}) {
  final contourArea = cv.contourArea(contour);
  if (!profile.acceptsArea(contourArea, imageArea)) return null;

  cv.VecPoint? approximation;
  try {
    final perimeter = cv.arcLength(contour, true);
    if (perimeter <= 0) return null;
    approximation = cv.approxPolyDP(contour, 0.018 * perimeter, true);

    // A document crop must originate from an observed, convex quadrilateral.
    // minAreaRect turns arbitrary nested contours (for example a portrait,
    // text panel, or seal inside a credential) into synthetic rectangles and
    // was the direct cause of partial smart-crops.
    if (approximation.length != 4 || !cv.isContourConvex(approximation)) {
      if (!allowAxisAlignedFallback) return null;
      return _axisAlignedCandidateFromContour(
        contour,
        contourArea: contourArea,
        imageArea: imageArea,
        profile: profile,
      );
    }
    final points = _orderPoints(
      List<cv.Point>.generate(4, (index) => approximation![index]),
    );

    final quadrilateralArea = _polygonArea(points);
    if (quadrilateralArea <= 0) return null;
    final rectangularity = contourArea / quadrilateralArea;
    if (rectangularity < 0.72 || rectangularity > 1.25) return null;
    final width = math.max(
      _distance(points[0], points[1]),
      _distance(points[2], points[3]),
    );
    final height = math.max(
      _distance(points[1], points[2]),
      _distance(points[3], points[0]),
    );
    if (width < 48 || height < 48) return null;
    if (!profile.acceptsAspectRatio(width, height)) return null;

    final horizontal = points.map((point) => point.x).toList();
    final vertical = points.map((point) => point.y).toList();
    return _DocumentCandidate(
      points: points,
      area: quadrilateralArea,
      width: width,
      height: height,
      left: horizontal.reduce(math.min),
      top: vertical.reduce(math.min),
      right: horizontal.reduce(math.max),
      bottom: vertical.reduce(math.max),
    );
  } finally {
    approximation?.dispose();
  }
}

_DocumentCandidate? _axisAlignedCandidateFromContour(
  cv.VecPoint contour, {
  required double contourArea,
  required double imageArea,
  required _DocumentDetectionProfile profile,
}) {
  final bounds = cv.boundingRect(contour);
  try {
    final boundingArea = (bounds.width * bounds.height).toDouble();
    if (bounds.width < 64 ||
        bounds.height < 64 ||
        !profile.acceptsArea(boundingArea, imageArea)) {
      return null;
    }

    final fillRatio = contourArea / boundingArea;
    if (fillRatio < 0.55 || fillRatio > 1.15) return null;
    if (!profile.acceptsAspectRatio(
      bounds.width.toDouble(),
      bounds.height.toDouble(),
    )) {
      return null;
    }

    final left = bounds.x;
    final top = bounds.y;
    final right = bounds.right;
    final bottom = bounds.bottom;
    return _DocumentCandidate(
      points: <cv.Point>[
        cv.Point(left, top),
        cv.Point(right, top),
        cv.Point(right, bottom),
        cv.Point(left, bottom),
      ],
      area: boundingArea,
      width: bounds.width.toDouble(),
      height: bounds.height.toDouble(),
      left: left,
      top: top,
      right: right,
      bottom: bottom,
    );
  } finally {
    bounds.dispose();
  }
}

bool _isDuplicateRegion(DocumentRegion candidate, DocumentRegion accepted) {
  final intersectionWidth = math.max(
    0,
    math.min(candidate.right, accepted.right) -
        math.max(candidate.left, accepted.left),
  );
  final intersectionHeight = math.max(
    0,
    math.min(candidate.bottom, accepted.bottom) -
        math.max(candidate.top, accepted.top),
  );
  final intersectionArea = intersectionWidth * intersectionHeight;
  final unionArea = candidate.area + accepted.area - intersectionArea;
  if (unionArea > 0 && intersectionArea / unionArea >= 0.7) return true;

  // A small portrait or text panel inside an accepted document must never be
  // emitted as another document. The candidates are ordered by area, so this
  // containment rule keeps the outer credential and rejects its inner region.
  final candidateCoverage = intersectionArea / math.max(candidate.area, 1);
  final acceptedCoverage = intersectionArea / math.max(accepted.area, 1);
  if (candidateCoverage >= 0.82 || acceptedCoverage >= 0.82) return true;

  final centerDistance = math.sqrt(
    math.pow(candidate.centerX - accepted.centerX, 2) +
        math.pow(candidate.centerY - accepted.centerY, 2),
  );
  final shorterSide = math.min(
    math.min(candidate.width, candidate.height),
    math.min(accepted.width, accepted.height),
  );
  final areaRatio = candidate.area > accepted.area
      ? candidate.area / accepted.area
      : accepted.area / candidate.area;
  return centerDistance < shorterSide * 0.15 && areaRatio < 1.35;
}

bool _isDuplicateCandidate(
  _DocumentCandidate candidate,
  _DocumentCandidate accepted,
) => _isDuplicateRegion(candidate.region, accepted.region);

Future<List<String>> _detectAndCropInIsolate(
  Map<String, dynamic> args, {
  bool Function()? isCancelled,
}) async {
  final imagePath = args['imagePath'] as String;
  final tempPath = args['tempPath'] as String;
  final jobId = args['jobId'] as String? ?? 'legacy';
  final requestedType = _documentTypeFromIndex(args['documentTypeIndex']);
  final profile = _detectionProfileFor(requestedType);
  if (isCancelled?.call() ?? false) return <String>[];
  if (requestedType == DocumentType.a4Document) {
    return <String>[imagePath];
  }
  cv.Mat? source;
  cv.Mat? gray;
  cv.Mat? blurred;
  cv.Mat? edges;
  cv.Mat? edgeClosed;
  cv.Mat? sensitiveEdges;
  cv.Mat? sensitiveEdgeClosed;
  cv.Mat? threshold;
  cv.Mat? thresholdClosed;
  cv.Mat? sensitiveThreshold;
  cv.Mat? sensitiveThresholdClosed;
  cv.Mat? foreground;
  cv.Mat? foregroundClosed;
  cv.Mat? kernel;
  cv.Mat? broadKernel;
  cv.Mat? foregroundKernel;
  var candidates = <_DocumentCandidate>[];
  final results = <String>[];

  Future<bool> collectCandidates(
    cv.Mat image,
    double imageArea, {
    int retrievalMode = cv.RETR_LIST,
    bool allowAxisAlignedFallback = false,
  }) async {
    final contourResult = cv.findContours(
      image,
      retrievalMode,
      cv.CHAIN_APPROX_SIMPLE,
    );
    final contours = contourResult.$1;
    final hierarchy = contourResult.$2;
    try {
      var inspected = 0;
      for (final contour in contours) {
        if (isCancelled?.call() ?? false) return false;
        // Let the worker control port process a cancellation while scanning a
        // noisy camera frame without sacrificing all candidate contours.
        if (inspected++ % 24 == 0) await Future<void>.delayed(Duration.zero);
        final candidate = _candidateFromContour(
          contour,
          imageArea: imageArea,
          profile: profile,
          allowAxisAlignedFallback: allowAxisAlignedFallback,
        );
        if (candidate == null ||
            candidates.any(
              (accepted) => _isDuplicateCandidate(candidate, accepted),
            )) {
          continue;
        }
        candidates.add(candidate);
      }
      return !(isCancelled?.call() ?? false);
    } finally {
      contours.dispose();
      hierarchy.dispose();
    }
  }

  try {
    source = cv.imdecode(File(imagePath).readAsBytesSync(), cv.IMREAD_COLOR);
    if (source.isEmpty) return results;

    // The isolated vision pass works on a bounded image for predictable
    // latency. Candidate points remain in the same coordinate space used for
    // the perspective crop below.
    const maximumAnalysisDimension = 1600;
    final largestDimension = math.max(source.cols, source.rows);
    if (largestDimension > maximumAnalysisDimension) {
      final scale = maximumAnalysisDimension / largestDimension;
      final resized = cv.resize(source, (0, 0), fx: scale, fy: scale);
      source.dispose();
      source = resized;
    }

    gray = cv.cvtColor(source, cv.COLOR_BGR2GRAY);
    blurred = cv.gaussianBlur(gray, (5, 5), 0);
    kernel = cv.getStructuringElement(cv.MORPH_RECT, (7, 7));
    broadKernel = cv.getStructuringElement(cv.MORPH_RECT, (11, 11));
    foregroundKernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));

    // Multiple complementary proposal masks are required for a sheet that
    // contains several cards: some card borders are sharp while others have
    // low contrast against the sheet. Every proposal still has to pass the
    // strict quadrilateral validation in _candidateFromContour.
    edges = cv.canny(blurred, 35, 110);
    edgeClosed = cv.morphologyEx(edges, cv.MORPH_CLOSE, kernel);
    sensitiveEdges = cv.canny(blurred, 15, 60);
    sensitiveEdgeClosed = cv.morphologyEx(
      sensitiveEdges,
      cv.MORPH_CLOSE,
      broadKernel,
    );
    threshold = cv.adaptiveThreshold(
      gray,
      255,
      cv.ADAPTIVE_THRESH_GAUSSIAN_C,
      cv.THRESH_BINARY_INV,
      31,
      8,
    );
    thresholdClosed = cv.morphologyEx(threshold, cv.MORPH_CLOSE, kernel);
    sensitiveThreshold = cv.adaptiveThreshold(
      gray,
      255,
      cv.ADAPTIVE_THRESH_GAUSSIAN_C,
      cv.THRESH_BINARY_INV,
      15,
      3,
    );
    sensitiveThresholdClosed = cv.morphologyEx(
      sensitiveThreshold,
      cv.MORPH_CLOSE,
      broadKernel,
    );

    // This mask separates darker/coloured documents from a light sheet.
    // It is deliberately evaluated with RETR_EXTERNAL so that a credential's
    // visible outer extent can be proposed without treating its portrait or
    // text blocks as separate documents.
    foreground = cv.threshold(gray, 160, 255, cv.THRESH_BINARY_INV).$2;
    foregroundClosed = cv.morphologyEx(
      foreground,
      cv.MORPH_CLOSE,
      foregroundKernel,
    );
    final imageArea = (source.rows * source.cols).toDouble();

    if (!await collectCandidates(edgeClosed, imageArea) ||
        !await collectCandidates(sensitiveEdgeClosed, imageArea) ||
        !await collectCandidates(thresholdClosed, imageArea) ||
        !await collectCandidates(sensitiveThresholdClosed, imageArea) ||
        !await collectCandidates(
          foregroundClosed,
          imageArea,
          retrievalMode: cv.RETR_EXTERNAL,
          allowAxisAlignedFallback: true,
        )) {
      return results;
    }

    final regions = selectDistinctDocumentRegions(
      candidates.map((candidate) => candidate.region),
    );
    final candidatesByRegion = <DocumentRegion, _DocumentCandidate>{
      for (final candidate in candidates) candidate.region: candidate,
    };
    candidates = regions
        .map((region) => candidatesByRegion[region])
        .whereType<_DocumentCandidate>()
        .toList(growable: false);

    for (final candidate in candidates) {
      if (isCancelled?.call() ?? false) return results;
      cv.VecPoint? sourcePoints;
      cv.VecPoint? destinationPoints;
      cv.Mat? transform;
      cv.Mat? warped;
      try {
        const padding = 8;
        final padded = <cv.Point>[
          cv.Point(
            _clampInt(candidate.points[0].x - padding, 0, source.cols - 1),
            _clampInt(candidate.points[0].y - padding, 0, source.rows - 1),
          ),
          cv.Point(
            _clampInt(candidate.points[1].x + padding, 0, source.cols - 1),
            _clampInt(candidate.points[1].y - padding, 0, source.rows - 1),
          ),
          cv.Point(
            _clampInt(candidate.points[2].x + padding, 0, source.cols - 1),
            _clampInt(candidate.points[2].y + padding, 0, source.rows - 1),
          ),
          cv.Point(
            _clampInt(candidate.points[3].x - padding, 0, source.cols - 1),
            _clampInt(candidate.points[3].y + padding, 0, source.rows - 1),
          ),
        ];
        final outputWidth = math.max(
          48,
          (candidate.width + padding * 2).round(),
        );
        final outputHeight = math.max(
          48,
          (candidate.height + padding * 2).round(),
        );
        sourcePoints = cv.VecPoint.fromList(padded);
        destinationPoints = cv.VecPoint.fromList(<cv.Point>[
          cv.Point(0, 0),
          cv.Point(outputWidth - 1, 0),
          cv.Point(outputWidth - 1, outputHeight - 1),
          cv.Point(0, outputHeight - 1),
        ]);
        transform = cv.getPerspectiveTransform(sourcePoints, destinationPoints);
        warped = cv.warpPerspective(source, transform, (
          outputWidth,
          outputHeight,
        ));
        final outputPath =
            '$tempPath/${TemporaryImageStore.uniqueJpegName('smart_cropped_', suffix: '-$jobId-${results.length}')}';
        if (cv.imwrite(outputPath, warped)) results.add(outputPath);
      } finally {
        sourcePoints?.dispose();
        destinationPoints?.dispose();
        transform?.dispose();
        warped?.dispose();
      }
    }
  } catch (_) {
    return <String>[];
  } finally {
    source?.dispose();
    gray?.dispose();
    blurred?.dispose();
    edges?.dispose();
    edgeClosed?.dispose();
    sensitiveEdges?.dispose();
    sensitiveEdgeClosed?.dispose();
    threshold?.dispose();
    thresholdClosed?.dispose();
    sensitiveThreshold?.dispose();
    sensitiveThresholdClosed?.dispose();
    foreground?.dispose();
    foregroundClosed?.dispose();
    kernel?.dispose();
    broadKernel?.dispose();
    foregroundKernel?.dispose();
  }
  return results;
}

String _preprocessForOcrInIsolate(Map<String, dynamic> args) {
  final imagePath = args['imagePath'] as String;
  final tempPath = args['tempPath'] as String;
  final jobId = args['jobId'] as String? ?? 'legacy';
  cv.Mat? source;
  cv.Mat? gray;
  cv.Mat? processed;
  try {
    source = cv.imdecode(File(imagePath).readAsBytesSync(), cv.IMREAD_COLOR);
    if (source.isEmpty) return imagePath;
    gray = cv.cvtColor(source, cv.COLOR_BGR2GRAY);
    final clahe = cv.CLAHE.empty();
    processed = clahe.apply(gray);
    clahe.dispose();
    final outputPath =
        '$tempPath/${TemporaryImageStore.uniqueJpegName('ocr_preprocessed_', suffix: '-$jobId')}';
    return cv.imwrite(outputPath, processed) ? outputPath : imagePath;
  } catch (_) {
    return imagePath;
  } finally {
    source?.dispose();
    gray?.dispose();
    processed?.dispose();
  }
}

void _ocrPreprocessWorkerEntry(Map<String, dynamic> args) {
  final resultPort = args['resultPort'] as SendPort;
  final controlPort = ReceivePort();
  var isCancelled = false;
  final controlSubscription = controlPort.listen((message) {
    if (message == 'cancel') isCancelled = true;
  });

  resultPort.send(<String, Object?>{
    'type': 'ready',
    'controlPort': controlPort.sendPort,
  });
  try {
    if (isCancelled) {
      resultPort.send(<String, Object?>{'type': 'cancelled'});
      return;
    }
    final outputPath = _preprocessForOcrInIsolate(<String, dynamic>{
      'imagePath': args['imagePath'] as String,
      'tempPath': args['tempPath'] as String,
      'jobId': args['jobId'] as String,
    });
    resultPort.send(<String, Object?>{
      'type': isCancelled ? 'cancelled' : 'completed',
      'outputPath': outputPath,
    });
  } catch (error) {
    resultPort.send(<String, Object?>{
      'type': 'error',
      'message': error.toString(),
    });
  } finally {
    unawaited(controlSubscription.cancel());
    controlPort.close();
  }
}

class _ScanWorkerCancelled implements Exception {
  const _ScanWorkerCancelled();
}

void _smartCropWorkerEntry(Map<String, dynamic> args) async {
  final resultPort = args['resultPort'] as SendPort;
  final controlPort = ReceivePort();
  var isCancelled = false;
  final controlSubscription = controlPort.listen((message) {
    if (message == 'cancel') isCancelled = true;
  });

  resultPort.send(<String, Object?>{
    'type': 'ready',
    'controlPort': controlPort.sendPort,
  });
  try {
    final outputPaths = await _detectAndCropInIsolate(
      args,
      isCancelled: () => isCancelled,
    );
    resultPort.send(<String, Object?>{
      'type': isCancelled ? 'cancelled' : 'completed',
      'outputPaths': outputPaths,
    });
  } catch (error) {
    resultPort.send(<String, Object?>{
      'type': 'error',
      'message': error.toString(),
    });
  } finally {
    await controlSubscription.cancel();
    controlPort.close();
  }
}

class ScannerService {
  static const _smartCropTimeout = Duration(seconds: 15);
  static const _classificationTimeout = Duration(seconds: 6);

  ScannerService({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  Future<File?> scanDocument({ImageSource source = ImageSource.camera}) async {
    final image = await _picker.pickImage(source: source);
    return image == null ? null : File(image.path);
  }

  Future<List<File>?> scanMultipleDocuments() async {
    final images = await _picker.pickMultiImage();
    return images.isEmpty
        ? null
        : images.map((image) => File(image.path)).toList();
  }

  Future<File?> applyFilter(File imageFile, bool highContrast) async {
    final bytes = await imageFile.readAsBytes();
    final processedBytes = await Isolate.run(() {
      var decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      decoded = img.grayscale(decoded);
      if (highContrast) {
        decoded = img.adjustColor(decoded, contrast: 1.5, exposure: 0.1);
      }
      return Uint8List.fromList(img.encodeJpg(decoded, quality: 90));
    });
    return processedBytes == null
        ? null
        : TemporaryImageStore.writeJpeg(processedBytes, prefix: 'edited_');
  }

  Future<String> _runOcrPreprocessWorker({
    required File imageFile,
    required String tempPath,
    required String jobId,
    required ScanCancellationToken token,
  }) async {
    if (token.isCancelled) throw const _ScanWorkerCancelled();

    final resultPort = ReceivePort();
    final completed = Completer<String>();
    Isolate? worker;
    SendPort? controlPort;
    late final StreamSubscription<dynamic> subscription;
    Timer? forcedTermination;
    var cancelRequested = false;

    void requestCancellation() {
      if (cancelRequested) return;
      cancelRequested = true;
      controlPort?.send('cancel');
      if (!completed.isCompleted) {
        completed.completeError(const _ScanWorkerCancelled());
      }
      forcedTermination ??= Timer(const Duration(milliseconds: 250), () {
        worker?.kill(priority: Isolate.immediate);
      });
    }

    token.addListener(requestCancellation);
    subscription = resultPort.listen((message) {
      if (message is! Map) return;
      switch (message['type']) {
        case 'ready':
          controlPort = message['controlPort'] as SendPort?;
          if (cancelRequested) controlPort?.send('cancel');
        case 'completed':
          final outputPath = message['outputPath'] as String?;
          if (outputPath != null && !completed.isCompleted) {
            completed.complete(outputPath);
          }
        case 'cancelled':
          if (!completed.isCompleted) {
            completed.completeError(const _ScanWorkerCancelled());
          }
        case 'error':
          if (!completed.isCompleted) {
            completed.completeError(
              StateError(
                message['message'] as String? ?? 'OCR preprocessing failed.',
              ),
            );
          }
      }
    });

    try {
      worker = await Isolate.spawn<Map<String, dynamic>>(
        _ocrPreprocessWorkerEntry,
        <String, dynamic>{
          'imagePath': imageFile.path,
          'tempPath': tempPath,
          'jobId': jobId,
          'resultPort': resultPort.sendPort,
        },
        errorsAreFatal: false,
      );
      return await completed.future.timeout(_classificationTimeout);
    } on TimeoutException {
      requestCancellation();
      throw TimeoutException('OCR preprocessing timed out.');
    } finally {
      token.removeListener(requestCancellation);
      forcedTermination?.cancel();
      worker?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      resultPort.close();
      if (cancelRequested) {
        await TemporaryImageStore.deleteManagedWithMarker(jobId);
      }
    }
  }

  Future<List<String>> _runSmartCropWorker({
    required File imageFile,
    required String tempPath,
    required String jobId,
    required DocumentType documentType,
    required ScanCancellationToken token,
  }) async {
    if (token.isCancelled) throw const _ScanWorkerCancelled();

    final resultPort = ReceivePort();
    final completed = Completer<List<String>>();
    Isolate? worker;
    SendPort? controlPort;
    StreamSubscription<dynamic>? subscription;
    Timer? forcedTermination;
    var cancelRequested = false;

    void requestCancellation() {
      if (cancelRequested) return;
      cancelRequested = true;
      controlPort?.send('cancel');
      if (!completed.isCompleted) {
        completed.completeError(const _ScanWorkerCancelled());
      }
      forcedTermination ??= Timer(const Duration(milliseconds: 250), () {
        worker?.kill(priority: Isolate.immediate);
      });
    }

    token.addListener(requestCancellation);
    subscription = resultPort.listen((message) {
      if (message is! Map) return;
      switch (message['type']) {
        case 'ready':
          controlPort = message['controlPort'] as SendPort?;
          if (cancelRequested) controlPort?.send('cancel');
        case 'completed':
          final paths = List<String>.from(
            (message['outputPaths'] as List<Object?>?) ?? const <Object?>[],
          );
          if (!completed.isCompleted) completed.complete(paths);
        case 'cancelled':
          if (!completed.isCompleted) {
            completed.completeError(const _ScanWorkerCancelled());
          }
        case 'error':
          if (!completed.isCompleted) {
            completed.completeError(
              StateError(message['message'] as String? ?? 'Smart scan failed.'),
            );
          }
      }
    });

    try {
      worker = await Isolate.spawn<Map<String, dynamic>>(
        _smartCropWorkerEntry,
        <String, dynamic>{
          'imagePath': imageFile.path,
          'tempPath': tempPath,
          'jobId': jobId,
          'documentTypeIndex': documentType.index,
          'resultPort': resultPort.sendPort,
        },
        errorsAreFatal: false,
      );
      return await completed.future.timeout(_smartCropTimeout);
    } on TimeoutException {
      requestCancellation();
      throw TimeoutException('Smart crop timed out.');
    } finally {
      token.removeListener(requestCancellation);
      forcedTermination?.cancel();
      worker?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      resultPort.close();
    }
  }

  DocumentClassification _classificationForRequestedType(DocumentType type) {
    return DocumentClassification(
      type: type,
      normalizedText: '',
      confidence: 1,
      reason: 'تم اعتماد نوع المستند المحدد من إعدادات المستخدم.',
      requiresManualReview: false,
    );
  }

  Future<SmartScanResult> processSmartRecognition(
    File imageFile, {
    DocumentType? documentType,
    ScanCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled ?? false) {
      return SmartScanResult(
        source: imageFile,
        files: const <File>[],
        classification: DocumentClassification.unknown,
        status: SmartScanStatus.cancelled,
        message: 'ألغيت المعالجة قبل البدء.',
      );
    }

    final requestedType = documentType ?? DocumentType.unknown;
    if (requestedType == DocumentType.a4Document) {
      if (!await imageFile.exists()) {
        return SmartScanResult(
          source: imageFile,
          files: const <File>[],
          classification: DocumentClassification.unknown,
          status: SmartScanStatus.manualReviewRequired,
          message: 'ملف ورقة A4 غير موجود؛ يُرجى اختيار الصورة من جديد.',
        );
      }
      if (cancellationToken?.isCancelled ?? false) {
        return SmartScanResult(
          source: imageFile,
          files: const <File>[],
          classification: DocumentClassification.unknown,
          status: SmartScanStatus.cancelled,
          message: 'ألغيت المعالجة.',
        );
      }
      return SmartScanResult(
        source: imageFile,
        files: List<File>.unmodifiable(<File>[imageFile]),
        classification: _classificationForRequestedType(requestedType),
        status: SmartScanStatus.succeeded,
        message: 'تم اعتماد الصورة كاملة كورقة A4.',
      );
    }

    await TemporaryImageStore.cleanupStale();
    final tempDirectory = await getTemporaryDirectory();
    final jobId = DateTime.now().microsecondsSinceEpoch.toString();
    List<String> outputPaths;
    try {
      outputPaths = await _runSmartCropWorker(
        imageFile: imageFile,
        tempPath: tempDirectory.path,
        jobId: jobId,
        documentType: requestedType,
        token: cancellationToken ?? ScanCancellationToken(),
      );
    } on _ScanWorkerCancelled {
      await TemporaryImageStore.deleteManagedWithMarker(jobId);
      return SmartScanResult(
        source: imageFile,
        files: const <File>[],
        classification: DocumentClassification.unknown,
        status: SmartScanStatus.cancelled,
        message: 'ألغيت المعالجة.',
      );
    } on TimeoutException {
      await TemporaryImageStore.deleteManagedWithMarker(jobId);
      return SmartScanResult(
        source: imageFile,
        files: const <File>[],
        classification: DocumentClassification.unknown,
        status: SmartScanStatus.manualReviewRequired,
        message: 'انتهت مهلة القص الذكي؛ يُرجى تحديد المستند يدوياً.',
      );
    } catch (_) {
      await TemporaryImageStore.deleteManagedWithMarker(jobId);
      return SmartScanResult(
        source: imageFile,
        files: const <File>[],
        classification: DocumentClassification.unknown,
        status: SmartScanStatus.manualReviewRequired,
        message: 'تعذر تحليل حدود المستند؛ يُرجى تحديده يدوياً.',
      );
    }

    if (cancellationToken?.isCancelled ?? false) {
      for (final outputPath in outputPaths) {
        await TemporaryImageStore.deleteIfManaged(File(outputPath));
      }
      return SmartScanResult(
        source: imageFile,
        files: const <File>[],
        classification: DocumentClassification.unknown,
        status: SmartScanStatus.cancelled,
        message: 'ألغيت المعالجة.',
      );
    }

    if (outputPaths.isEmpty) {
      return SmartScanResult(
        source: imageFile,
        files: const <File>[],
        classification: DocumentClassification.unknown,
        status: SmartScanStatus.manualReviewRequired,
        message: 'لم يُعثر على مستند موثوق؛ يُرجى تحديده يدوياً.',
      );
    }

    final files = List<File>.unmodifiable(outputPaths.map(File.new));
    if (cancellationToken?.isCancelled ?? false) {
      for (final file in files) {
        await TemporaryImageStore.deleteIfManaged(file);
      }
      return SmartScanResult(
        source: imageFile,
        files: const <File>[],
        classification: DocumentClassification.unknown,
        status: SmartScanStatus.cancelled,
        message: 'ألغيت المعالجة.',
      );
    }

    DocumentClassification classification;
    try {
      classification = requestedType == DocumentType.unknown
          ? await classifyDocument(
              files.first,
              cancellationToken: cancellationToken,
            ).timeout(
              _classificationTimeout,
              onTimeout: () => const DocumentClassification(
                type: DocumentType.unknown,
                normalizedText: '',
                confidence: 0,
                reason: 'تجاوز التعرف النصي المهلة؛ راجع نوع المستند يدوياً.',
                requiresManualReview: true,
              ),
            )
          : _classificationForRequestedType(requestedType);
    } on _ScanWorkerCancelled {
      for (final file in files) {
        await TemporaryImageStore.deleteIfManaged(file);
      }
      return SmartScanResult(
        source: imageFile,
        files: const <File>[],
        classification: DocumentClassification.unknown,
        status: SmartScanStatus.cancelled,
        message: 'ألغيت المعالجة.',
      );
    }
    final status = classification.requiresManualReview
        ? SmartScanStatus.manualReviewRequired
        : SmartScanStatus.succeeded;
    return SmartScanResult(
      source: imageFile,
      files: files,
      classification: classification,
      status: status,
      message: classification.requiresManualReview
          ? 'اكتمل القص، لكن تصنيف المستند يحتاج مراجعة يدوية.'
          : 'اكتمل القص والتصنيف بثقة مناسبة.',
    );
  }

  Future<SmartScanBatchResult> processBatchSmartRecognition(
    List<File> imageFiles, {
    DocumentType? documentType,
    void Function(int current, int total)? onProgress,
    ScanCancellationToken? cancellationToken,
  }) async {
    final activeToken = cancellationToken ?? ScanCancellationToken();
    final results = <File, SmartScanResult>{};
    for (var index = 0; index < imageFiles.length; index++) {
      if (activeToken.isCancelled) {
        return SmartScanBatchResult(
          results: Map.unmodifiable(results),
          wasCancelled: true,
        );
      }
      final source = imageFiles[index];
      try {
        final result = await processSmartRecognition(
          source,
          documentType: documentType,
          cancellationToken: activeToken,
        );
        results[source] = result;
        if (result.status == SmartScanStatus.cancelled ||
            activeToken.isCancelled) {
          return SmartScanBatchResult(
            results: Map.unmodifiable(results),
            wasCancelled: true,
          );
        }
      } catch (_) {
        if (activeToken.isCancelled) {
          return SmartScanBatchResult(
            results: Map.unmodifiable(results),
            wasCancelled: true,
          );
        }
        results[source] = SmartScanResult(
          source: source,
          files: const <File>[],
          classification: DocumentClassification.unknown,
          status: SmartScanStatus.failed,
          message: 'تعذرت معالجة هذه الصورة؛ يُرجى قصها يدوياً.',
        );
      }
      if (!activeToken.isCancelled) {
        onProgress?.call(index + 1, imageFiles.length);
      }
    }
    return SmartScanBatchResult(
      results: Map.unmodifiable(results),
      wasCancelled: false,
    );
  }

  Future<DocumentClassification> classifyDocument(
    File imageFile, {
    ScanCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancelled ?? false) {
      throw const _ScanWorkerCancelled();
    }
    final activeToken = cancellationToken ?? ScanCancellationToken();
    final tempDirectory = await getTemporaryDirectory();
    final jobId = DateTime.now().microsecondsSinceEpoch.toString();
    final preprocessedPath = await _runOcrPreprocessWorker(
      imageFile: imageFile,
      tempPath: tempDirectory.path,
      jobId: jobId,
      token: activeToken,
    );
    final preprocessedFile = File(preprocessedPath);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    var recognizerClosedByCancellation = false;
    void closeRecognizerOnCancellation() {
      if (recognizerClosedByCancellation) return;
      recognizerClosedByCancellation = true;
      unawaited(recognizer.close());
    }

    activeToken.addListener(closeRecognizerOnCancellation);
    final recognizerTimeout = Timer(
      _classificationTimeout,
      closeRecognizerOnCancellation,
    );
    try {
      if (activeToken.isCancelled) {
        throw const _ScanWorkerCancelled();
      }
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(preprocessedPath),
      );
      if (activeToken.isCancelled) {
        throw const _ScanWorkerCancelled();
      }
      return _classifyRecognizedText(recognized.text);
    } on _ScanWorkerCancelled {
      rethrow;
    } catch (_) {
      return const DocumentClassification(
        type: DocumentType.unknown,
        normalizedText: '',
        confidence: 0,
        reason: 'تعذر استخراج النص تلقائياً؛ اختر نوع المستند يدوياً.',
        requiresManualReview: true,
      );
    } finally {
      recognizerTimeout.cancel();
      activeToken.removeListener(closeRecognizerOnCancellation);
      if (!recognizerClosedByCancellation) await recognizer.close();
      if (preprocessedPath != imageFile.path) {
        await TemporaryImageStore.deleteIfManaged(preprocessedFile);
      }
    }
  }

  DocumentClassification _classifyRecognizedText(String rawText) {
    final text = _normalizeForMatching(rawText);
    const keywords = <DocumentType, List<String>>{
      DocumentType.nationalId: <String>[
        'البطاقة الوطنية',
        'بطاقه وطنيه',
        'national id',
      ],
      DocumentType.housingCard: <String>[
        'بطاقة السكن',
        'بطاقه السكن',
        'housing card',
      ],
      DocumentType.rationCard: <String>[
        'البطاقة التموينية',
        'بطاقه تموينيه',
        'ration card',
      ],
      DocumentType.passport: <String>[
        'جواز السفر',
        'jawaz alsafar',
        'passport',
      ],
    };

    for (final entry in keywords.entries) {
      if (entry.value.any(text.contains)) {
        return DocumentClassification(
          type: entry.key,
          normalizedText: text,
          confidence: 0.85,
          reason: 'تطابق عنوان مستند معروف في النص المستخرج.',
          requiresManualReview: false,
        );
      }
    }

    return DocumentClassification(
      type: DocumentType.unknown,
      normalizedText: text,
      confidence: 0,
      reason:
          'لا يدعم محرك OCR الحالي العربية أصلاً؛ لا يمكن الاعتماد على تصنيف عربي تلقائي.',
      requiresManualReview: true,
    );
  }

  String _normalizeForMatching(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[\u064B-\u065F\u0670\u0640]'), '')
        .replaceAll('أ', 'ا')
        .replaceAll('إ', 'ا')
        .replaceAll('آ', 'ا')
        .replaceAll('ة', 'ه')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
