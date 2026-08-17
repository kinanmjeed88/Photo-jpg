import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
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

void _logScannerError(String operation, Object error, StackTrace stackTrace) {
  developer.log(
    'Scanner operation failed: $operation',
    name: 'PhotoJpg.ScannerService',
    error: error,
    stackTrace: stackTrace,
  );
}

/// Describes the independent detector passes that are allowed for one image.
///
/// A requested UI type is intentionally converted into a plan before the
/// isolate starts. This prevents one specialist (notably passport OCR) from
/// replacing a multi-document request and makes every detector contribute
/// candidates to the same confidence and review pipeline.
class DetectionPlan {
  const DetectionPlan._(this.types);

  factory DetectionPlan.forType(DocumentType requestedType) =>
      DetectionPlan.forTypes(<DocumentType>[requestedType]);

  factory DetectionPlan.forTypes(Iterable<DocumentType> requestedTypes) {
    final expanded = <DocumentType>[];
    for (final requestedType in requestedTypes) {
      switch (requestedType) {
        case DocumentType.a4Document:
          // A4 is a full-frame mode and must remain exclusive.
          return const DetectionPlan._(<DocumentType>[DocumentType.a4Document]);
        case DocumentType.allDocuments:
          expanded
            ..add(DocumentType.housingCard)
            ..add(DocumentType.nationalId)
            ..add(DocumentType.rationCard);
        case DocumentType.unknown:
          expanded
            ..add(DocumentType.housingCard)
            ..add(DocumentType.nationalId)
            ..add(DocumentType.rationCard)
            ..add(DocumentType.passport);
        case DocumentType.housingCard:
        case DocumentType.nationalId:
        case DocumentType.rationCard:
        case DocumentType.passport:
          expanded.add(requestedType);
      }
    }

    final uniqueTypes = <DocumentType>[];
    for (final type in expanded) {
      if (!uniqueTypes.contains(type)) uniqueTypes.add(type);
    }
    if (uniqueTypes.isEmpty) {
      uniqueTypes.addAll(const <DocumentType>[
        DocumentType.housingCard,
        DocumentType.nationalId,
        DocumentType.rationCard,
        DocumentType.passport,
      ]);
    }
    return DetectionPlan._(List<DocumentType>.unmodifiable(uniqueTypes));
  }

  final List<DocumentType> types;

  DocumentType get resultType {
    if (isA4Only) return DocumentType.a4Document;
    return types.length == 1 ? types.first : DocumentType.allDocuments;
  }

  List<int> get typeIndices =>
      List<int>.unmodifiable(types.map((type) => type.index));

  bool contains(DocumentType type) => types.contains(type);

  bool get isA4Only =>
      types.length == 1 && types.first == DocumentType.a4Document;
}

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

class ScanPerformanceMetrics {
  const ScanPerformanceMetrics({
    this.stageMilliseconds = const <String, int>{},
    this.peakMemoryBytes = 0,
  });

  const ScanPerformanceMetrics.empty()
    : stageMilliseconds = const <String, int>{},
      peakMemoryBytes = 0;

  final Map<String, int> stageMilliseconds;
  final int peakMemoryBytes;

  bool get isEmpty => stageMilliseconds.isEmpty && peakMemoryBytes <= 0;
}

class SmartScanResult {
  const SmartScanResult({
    required this.source,
    required this.files,
    required this.classification,
    required this.status,
    required this.message,
    this.cropConfidence = 0,
    this.detectedDocumentCount = 0,
    this.cropReviewReason = '',
    this.manualReviewRegions = const <DocumentRegion>[],
    this.performanceMetrics = const ScanPerformanceMetrics.empty(),
  });

  final File source;
  final List<File> files;
  final DocumentClassification classification;
  final SmartScanStatus status;
  final String message;

  /// Aggregate boundary confidence retained for compatibility and diagnostics.
  /// It is no longer used to discard every crop in a source image.
  final double cropConfidence;
  final int detectedDocumentCount;
  final String cropReviewReason;

  /// Regions that need a human boundary decision. Accepted crops remain in
  /// [files] and are never discarded because this list is non-empty.
  final List<DocumentRegion> manualReviewRegions;
  final ScanPerformanceMetrics performanceMetrics;

  bool get requiresCropReview => manualReviewRegions.isNotEmpty;

  /// True only when the source has no safe automatic output, or processing
  /// failed. A low-confidence crop with other accepted crops is a partial
  /// review, not a full-image fallback.
  bool get requiresManualFallback =>
      files.isEmpty &&
      manualReviewRegions.isEmpty &&
      (status == SmartScanStatus.manualReviewRequired ||
          status == SmartScanStatus.failed ||
          classification.requiresManualReview);
}

class _SmartCropOutput {
  const _SmartCropOutput({
    required this.paths,
    required this.confidence,
    required this.detectedDocumentCount,
    required this.reviewReason,
    this.reviewRegions = const <DocumentRegion>[],
    this.performanceMetrics = const ScanPerformanceMetrics.empty(),
  });

  final List<String> paths;
  final double confidence;
  final int detectedDocumentCount;
  final String reviewReason;
  final List<DocumentRegion> reviewRegions;
  final ScanPerformanceMetrics performanceMetrics;
}

Map<String, Object> _documentRegionToMessage(DocumentRegion region) =>
    <String, Object>{
      'left': region.left,
      'top': region.top,
      'right': region.right,
      'bottom': region.bottom,
      'area': region.area,
      'reason': region.reason,
    };

Map<String, Object> _performanceMetricsToMessage(
  ScanPerformanceMetrics metrics,
) => <String, Object>{
  'stageMilliseconds': metrics.stageMilliseconds,
  'peakMemoryBytes': metrics.peakMemoryBytes,
};

ScanPerformanceMetrics _performanceMetricsFromMessage(Object? value) {
  if (value is! Map) return const ScanPerformanceMetrics.empty();
  final rawStages = value['stageMilliseconds'];
  final stageMilliseconds = <String, int>{};
  if (rawStages is Map) {
    rawStages.forEach((key, stage) {
      if (key is String && stage is num) {
        stageMilliseconds[key] = stage.round();
      }
    });
  }
  final peakMemoryBytes = (value['peakMemoryBytes'] as num?)?.toInt() ?? 0;
  return ScanPerformanceMetrics(
    stageMilliseconds: Map<String, int>.unmodifiable(stageMilliseconds),
    peakMemoryBytes: math.max(0, peakMemoryBytes),
  );
}

DocumentRegion? _documentRegionFromMessage(Object? value) {
  if (value is! Map) return null;
  final left = (value['left'] as num?)?.toInt();
  final top = (value['top'] as num?)?.toInt();
  final right = (value['right'] as num?)?.toInt();
  final bottom = (value['bottom'] as num?)?.toInt();
  final area = (value['area'] as num?)?.toDouble();
  final reason = value['reason'] as String? ?? '';
  if (left == null ||
      top == null ||
      right == null ||
      bottom == null ||
      area == null) {
    return null;
  }
  if (right <= left || bottom <= top || area <= 0) return null;
  return DocumentRegion(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    area: area,
    reason: reason,
  );
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
    this.reason = '',
  });

  final int left;
  final int top;
  final int right;
  final int bottom;
  final double area;
  final String reason;

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

/// Maps detector coordinates back to the original decoded image.
///
/// The manual crop screen consumes source-image coordinates. Keeping this
/// conversion as a pure function makes the resize contract explicit and
/// prevents review proposals from being displayed at analysis-image offsets.
DocumentRegion scaleDocumentRegionToSource(
  DocumentRegion region, {
  required int analysisWidth,
  required int analysisHeight,
  required int sourceWidth,
  required int sourceHeight,
}) {
  if (analysisWidth <= 0 ||
      analysisHeight <= 0 ||
      sourceWidth <= 0 ||
      sourceHeight <= 0) {
    return region;
  }
  final scaleX = sourceWidth / analysisWidth;
  final scaleY = sourceHeight / analysisHeight;
  final left = _clampInt(
    (region.left * scaleX).round(),
    0,
    math.max(0, sourceWidth - 1),
  );
  final top = _clampInt(
    (region.top * scaleY).round(),
    0,
    math.max(0, sourceHeight - 1),
  );
  final right = _clampInt(
    (region.right * scaleX).round(),
    left + 1,
    sourceWidth,
  );
  final bottom = _clampInt(
    (region.bottom * scaleY).round(),
    top + 1,
    sourceHeight,
  );
  return DocumentRegion(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    area: ((right - left) * (bottom - top)).toDouble(),
    reason: region.reason,
  );
}

List<DocumentRegion> scaleDocumentRegionsToSource(
  Iterable<DocumentRegion> regions, {
  required int analysisWidth,
  required int analysisHeight,
  required int sourceWidth,
  required int sourceHeight,
}) => List<DocumentRegion>.unmodifiable(
  regions.map(
    (region) => scaleDocumentRegionToSource(
      region,
      analysisWidth: analysisWidth,
      analysisHeight: analysisHeight,
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
    ),
  ),
);

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
    this.requiresGreenTint = false,
    this.rejectsGreenTint = false,
  });

  final DocumentType type;
  final double minimumLongToShortRatio;
  final double maximumLongToShortRatio;
  final double minimumAreaRatio;
  final double maximumAreaRatio;
  final bool requiresGreenTint;
  final bool rejectsGreenTint;

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
    case DocumentType.allDocuments:
      return const _DocumentDetectionProfile(
        type: DocumentType.allDocuments,
        minimumLongToShortRatio: 1.15,
        maximumLongToShortRatio: 2.05,
        // Four cards can legitimately occupy only 2–4% each of a portrait
        // capture. The old 5% floor discarded every real card in a layout like
        // 1000310134.jpg before deduplication or manual review could see it.
        // Inner portraits and seals are still rejected by the quadrilateral,
        // aspect-ratio, frame-contact, and confidence gates below.
        minimumAreaRatio: 0.012,
        // A contour covering most of the light capture sheet is a background
        // boundary, not one of the four cards placed on it. A4 has its own
        // explicit passthrough mode and does not use this profile.
        maximumAreaRatio: 0.65,
        rejectsGreenTint: true,
      );
    case DocumentType.passport:
      // The passport is commonly captured either portrait (~0.7 W/H) or
      // rotated landscape. The comparison is therefore orientation agnostic.
      // maximumAreaRatio 0.995 accepts flat scans whose page fills nearly the
      // whole frame; _fullFrameCandidateForPassport is the last resort when
      // no geometric candidate survives at all.
      return const _DocumentDetectionProfile(
        type: DocumentType.passport,
        minimumLongToShortRatio: 1.33,
        maximumLongToShortRatio: 1.55,
        minimumAreaRatio: 0.008,
        maximumAreaRatio: 0.995,
      );
    case DocumentType.nationalId:
      return _DocumentDetectionProfile(
        type: type,
        minimumLongToShortRatio: 1.4,
        maximumLongToShortRatio: 1.7,
        minimumAreaRatio: 0.008,
        maximumAreaRatio: 0.65,
        // The national/unified card is blue-lilac in the supported capture
        // layout. Do not let the green housing form satisfy this profile.
        rejectsGreenTint: true,
      );
    case DocumentType.housingCard:
      // The housing card is detected exclusively through its dedicated
      // stamp-anchored path (_housingCardStampCandidates), so the shared
      // geometric profile is only a fallback shape contract for that path
      // (aspect ratio and area of the expanded seal box). The green tint is
      // enforced there by the seal mask itself; this flag still guards any
      // residual geometric candidate from slipping in as housing stock.
      return const _DocumentDetectionProfile(
        type: DocumentType.housingCard,
        minimumLongToShortRatio: 1.15,
        maximumLongToShortRatio: 2.05,
        // The expanded stamp box can legitimately be larger than the generic
        // geometric-card ceiling, especially in a close-up single-card photo.
        minimumAreaRatio: 0.01,
        maximumAreaRatio: 0.95,
        requiresGreenTint: true,
      );
    case DocumentType.rationCard:
      return const _DocumentDetectionProfile(
        type: DocumentType.rationCard,
        minimumLongToShortRatio: 1.4,
        maximumLongToShortRatio: 1.7,
        minimumAreaRatio: 0.008,
        maximumAreaRatio: 0.65,
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

List<DocumentType> _detectionTypesFromArgs(Map<String, dynamic> args) {
  final rawTypes = args['detectionTypeIndices'];
  if (rawTypes is List) {
    final types = rawTypes
        .map(_documentTypeFromIndex)
        .where((type) => type != DocumentType.unknown)
        .toSet()
        .toList(growable: false);
    if (types.isNotEmpty) return types;
  }
  return <DocumentType>[_documentTypeFromIndex(args['documentTypeIndex'])];
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
    this.confidence = 0,
    this.evidenceCount = 1,
    this.documentEvidence = 0,
    this.detectedType = DocumentType.unknown,
    this.isAxisAligned = false,
  });

  final List<cv.Point> points;
  final double area;
  final double width;
  final double height;
  final int left;
  final int top;
  final int right;
  final int bottom;

  /// Geometry-only confidence. It is intentionally separate from OCR/type
  /// confidence because a correctly classified image can still have a bad
  /// crop boundary.
  final double confidence;

  /// Number of independent proposal masks or specialist detectors supporting
  /// this same region. It is used as a stability signal, not as a replacement
  /// for geometry validation.
  final int evidenceCount;

  /// Optional type-specific visual evidence, such as a passport MRZ-like
  /// lower-band pattern. It is deliberately bounded and never bypasses the
  /// geometric profile.
  final double documentEvidence;

  /// The detector profile that produced this candidate. Keeping this metadata
  /// with the candidate allows one image to contain housing, unified, and
  /// ration-card proposals without collapsing them into one requested type.
  final DocumentType detectedType;

  /// Axis-aligned boxes are useful proposals, but they do not prove that the
  /// visible outer boundary is the document boundary. They require stronger
  /// independent evidence before automatic export.
  final bool isAxisAligned;

  _DocumentCandidate copyWith({
    double? confidence,
    int? evidenceCount,
    double? documentEvidence,
    DocumentType? detectedType,
    bool? isAxisAligned,
  }) {
    return _DocumentCandidate(
      points: points,
      area: area,
      width: width,
      height: height,
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      confidence: confidence ?? this.confidence,
      evidenceCount: evidenceCount ?? this.evidenceCount,
      documentEvidence: documentEvidence ?? this.documentEvidence,
      detectedType: detectedType ?? this.detectedType,
      isAxisAligned: isAxisAligned ?? this.isAxisAligned,
    );
  }

  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;

  DocumentRegion get region => DocumentRegion(
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    area: area,
    reason: _candidateReviewReason(this),
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

double _geometryConfidence({
  required double rectangularity,
  required double width,
  required double height,
  required _DocumentDetectionProfile profile,
}) {
  final ratio = math.max(width, height) / math.max(1, math.min(width, height));
  final ratioCenter =
      (profile.minimumLongToShortRatio + profile.maximumLongToShortRatio) / 2;
  final ratioHalfRange =
      (profile.maximumLongToShortRatio - profile.minimumLongToShortRatio) / 2;
  final ratioScore = ratioHalfRange <= 0
      ? 0.0
      : (1 - ((ratio - ratioCenter).abs() / ratioHalfRange)).clamp(0.0, 1.0);
  final shapeScore = ((rectangularity - 0.72) / 0.28).clamp(0.0, 1.0);
  return (shapeScore * 0.65) + (ratioScore * 0.35);
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
      confidence: _geometryConfidence(
        rectangularity: rectangularity,
        width: width,
        height: height,
        profile: profile,
      ),
      detectedType: profile.type,
    );
  } finally {
    approximation?.dispose();
  }
}

double _passportMrzEvidence({
  required cv.Mat gray,
  required _DocumentCandidate candidate,
}) {
  final left = _clampInt(candidate.left, 0, gray.cols - 1);
  final top = _clampInt(candidate.top, 0, gray.rows - 1);
  final right = _clampInt(candidate.right, left + 1, gray.cols);
  final bottom = _clampInt(candidate.bottom, top + 1, gray.rows);
  final width = right - left;
  final height = bottom - top;
  if (width < 64 || height < 64) return 0;

  final bandTop = _clampInt(top + (height * 0.68).round(), top, bottom - 1);
  final bandHeight = math.max(1, bottom - bandTop);
  cv.Mat? band;
  cv.Mat? bandEdges;
  try {
    band = gray.region(cv.Rect(left, bandTop, width, bandHeight));
    bandEdges = cv.canny(band, 30, 110);
    final density =
        cv.countNonZero(bandEdges) / math.max(1, width * bandHeight);
    // MRZ-like lower bands contain dense, repeated dark glyph strokes. The
    // score is only an additional signal; geometry and page coverage remain
    // mandatory, so a random text block cannot pass by itself.
    return ((density - 0.015) / 0.12).clamp(0.0, 1.0).toDouble();
  } finally {
    bandEdges?.dispose();
    band?.dispose();
  }
}

bool _candidateHasGreenTint(cv.Mat source, _DocumentCandidate candidate) {
  final left = _clampInt(candidate.left, 0, source.cols - 1);
  final top = _clampInt(candidate.top, 0, source.rows - 1);
  final right = _clampInt(candidate.right, left + 1, source.cols);
  final bottom = _clampInt(candidate.bottom, top + 1, source.rows);
  final width = right - left;
  final height = bottom - top;
  if (width < 8 || height < 8) return false;

  cv.Rect? rect;
  cv.Mat? roi;
  cv.Mat? hsv;
  cv.Mat? greenMask;
  cv.Mat? brightMask;
  cv.Mat? saturatedMask;
  cv.Mat? stableMask;
  try {
    rect = cv.Rect(left, top, width, height);
    roi = source.region(rect);
    hsv = cv.cvtColor(roi, cv.COLOR_BGR2HSV);

    // Use two hue bands because camera white-balance can move the Iraqi
    // housing-card seal and body across the green/yellow-green boundary.
    cv.Mat range(cv.Scalar lower, cv.Scalar upper) {
      try {
        return cv.inRangebyScalar(hsv!, lower, upper);
      } finally {
        lower.dispose();
        upper.dispose();
      }
    }

    final firstRange = range(cv.Scalar(28, 45, 35), cv.Scalar(92, 255, 255));
    final secondRange = range(cv.Scalar(18, 65, 45), cv.Scalar(35, 255, 255));
    try {
      greenMask = cv.bitwiseOR(firstRange, secondRange);
    } finally {
      firstRange.dispose();
      secondRange.dispose();
    }

    brightMask = range(cv.Scalar(0, 0, 28), cv.Scalar(179, 255, 255));
    saturatedMask = range(cv.Scalar(0, 35, 35), cv.Scalar(179, 255, 255));
    stableMask = cv.bitwiseAND(greenMask, brightMask);
    final stableSaturated = cv.bitwiseAND(stableMask, saturatedMask);
    try {
      final area = math.max(1, width * height).toDouble();
      final greenCoverage = cv.countNonZero(greenMask) / area;
      final stableCoverage = cv.countNonZero(stableMask) / area;
      final stableSaturatedCoverage = cv.countNonZero(stableSaturated) / area;
      return greenCoverage >= 0.08 &&
          stableCoverage >= 0.06 &&
          stableSaturatedCoverage >= 0.035;
    } finally {
      stableSaturated.dispose();
    }
  } finally {
    rect?.dispose();
    roi?.dispose();
    hsv?.dispose();
    greenMask?.dispose();
    brightMask?.dispose();
    saturatedMask?.dispose();
    stableMask?.dispose();
  }
}

bool _matchesVisualProfile(
  cv.Mat source,
  _DocumentCandidate candidate,
  _DocumentDetectionProfile profile,
) {
  final hasGreenTint = _candidateHasGreenTint(source, candidate);
  if (profile.requiresGreenTint) return hasGreenTint;
  if (profile.rejectsGreenTint) return !hasGreenTint;
  return true;
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
      confidence: _geometryConfidence(
        rectangularity: fillRatio,
        width: bounds.width.toDouble(),
        height: bounds.height.toDouble(),
        profile: profile,
      ),
      detectedType: profile.type,
      isAxisAligned: true,
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

  // A portrait or text panel inside an accepted document must never be
  // emitted as another document. The independent saturation proposal creates
  // the four real cards before this pass, while this containment rule removes
  // only inner regions from any broader contour.
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
) {
  final candidateType = candidate.detectedType;
  final acceptedType = accepted.detectedType;
  final typesAreKnown =
      candidateType != DocumentType.unknown &&
      acceptedType != DocumentType.unknown;
  if (typesAreKnown && candidateType != acceptedType) return false;
  return _isDuplicateRegion(candidate.region, accepted.region);
}

String _candidateReviewReason(_DocumentCandidate candidate) {
  final reasons = <String>[];
  if (candidate.confidence < 0.55) {
    reasons.add('حدود المستند ضعيفة');
  }
  if (candidate.evidenceCount < 2) {
    reasons.add('دليل كشف واحد فقط');
  }
  if (candidate.documentEvidence < 0.25) {
    reasons.add('الدليل النوعي غير كافٍ');
  }
  if (candidate.isAxisAligned && candidate.evidenceCount < 2) {
    reasons.add('حدود محورية تحتاج دعماً مستقلاً');
  }
  return reasons.isEmpty
      ? 'تحتاج مراجعة بسبب التقييم المركب'
      : reasons.join('، ');
}

double _candidateQuality(_DocumentCandidate candidate) {
  final stability = (candidate.evidenceCount / 3).clamp(0.0, 1.0).toDouble();
  final typeEvidence = candidate.documentEvidence.clamp(0.0, 1.0).toDouble();

  // Type-specific evidence is optional for geometric multi-document crops.
  // National and ration cards may have no dedicated visual/OCR signal, but a
  // strong quadrilateral supported by one or more independent masks is still
  // a valid document. Keep the geometry score self-sufficient and only use
  // type evidence as a bonus when it is actually available.
  if (typeEvidence <= 0) {
    return (candidate.confidence * 0.80 + stability * 0.20)
        .clamp(0.0, 1.0)
        .toDouble();
  }

  return (candidate.confidence * 0.65 + stability * 0.15 + typeEvidence * 0.20)
      .clamp(0.0, 1.0)
      .toDouble();
}

List<_DocumentCandidate> _selectReviewCandidates(
  Iterable<_DocumentCandidate> candidates, {
  required int detectedDocumentCount,
}) {
  final ordered = List<_DocumentCandidate>.of(candidates)
    ..sort((first, second) {
      final quality = _candidateQuality(
        first,
      ).compareTo(_candidateQuality(second));
      return quality != 0 ? quality : first.area.compareTo(second.area);
    });

  // The review queue scales with the number of detected documents instead of
  // silently truncating every image to an arbitrary fixed count. A bounded
  // ceiling remains in place as a protection against noisy contours.
  final reviewLimit = math
      .min(20, math.max(5, math.max(detectedDocumentCount, 1)))
      .toInt();
  return ordered.take(reviewLimit).toList(growable: false);
}

double _automaticAcceptanceThreshold(_DocumentDetectionProfile profile) {
  switch (profile.type) {
    case DocumentType.passport:
      // A passport crop must have strong page geometry. The MRZ-like signal
      // improves the score but can never compensate for a small inner region.
      return 0.64;
    case DocumentType.housingCard:
      // Housing cards may have weak outer edges because of plastic sleeves;
      // the stamp specialist path supplies the additional evidence.
      return 0.58;
    case DocumentType.allDocuments:
      // Multi-document captures often produce a valid rectangle from a single
      // complementary mask. Do not force five independent masks for a card
      // that already has strong geometry and a valid area prior.
      return 0.54;
    case DocumentType.nationalId:
      return 0.54;
    case DocumentType.rationCard:
    case DocumentType.a4Document:
    case DocumentType.unknown:
      return 0.60;
  }
}

bool _isAutomaticallyAcceptable(
  _DocumentCandidate candidate,
  _DocumentDetectionProfile profile,
) {
  if (_candidateQuality(candidate) < _automaticAcceptanceThreshold(profile)) {
    return false;
  }
  // An axis-aligned rectangle is a proposal, not proof of the outer document
  // boundary. Export it only after an independent mask or specialist signal
  // supports it; otherwise preserve it for manual review.
  if (candidate.isAxisAligned &&
      candidate.evidenceCount < 2 &&
      candidate.documentEvidence < 0.35) {
    return false;
  }
  return true;
}

void _mergeCandidate(
  List<_DocumentCandidate> candidates,
  _DocumentCandidate candidate,
) {
  final duplicateIndex = candidates.indexWhere(
    (existing) => _isDuplicateCandidate(candidate, existing),
  );
  if (duplicateIndex < 0) {
    candidates.add(candidate);
    return;
  }
  final existing = candidates[duplicateIndex];
  final stronger = _candidateQuality(candidate) > _candidateQuality(existing)
      ? candidate
      : existing;
  candidates[duplicateIndex] = stronger.copyWith(
    confidence: math.max(existing.confidence, candidate.confidence),
    evidenceCount: existing.evidenceCount + candidate.evidenceCount,
    documentEvidence: math.max(
      existing.documentEvidence,
      candidate.documentEvidence,
    ),
  );
}

List<_DocumentCandidate> _selectDistinctCandidates(
  Iterable<_DocumentCandidate> candidates,
) {
  final ordered = List<_DocumentCandidate>.of(candidates)
    ..sort((first, second) {
      final quality = _candidateQuality(
        second,
      ).compareTo(_candidateQuality(first));
      return quality != 0 ? quality : second.area.compareTo(first.area);
    });
  final selected = <_DocumentCandidate>[];
  for (final candidate in ordered) {
    if (selected.every(
      (accepted) => !_isDuplicateCandidate(candidate, accepted),
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

bool _isLikelyDocumentCandidate({
  required cv.Mat source,
  required _DocumentCandidate candidate,
  required _DocumentDetectionProfile profile,
}) {
  final imageArea = (source.rows * source.cols).toDouble();
  if (imageArea <= 0) return false;
  final areaRatio = candidate.area / imageArea;

  if (profile.type == DocumentType.allDocuments) {
    // Reject small internal objects that previously became face/logo crops.
    if (areaRatio < profile.minimumAreaRatio) return false;

    // Use a proportional frame margin. Resized images rarely land exactly on
    // the last pixel, so a one-pixel test misses large background contours.
    final frameMarginX = math.max(2, (source.cols * 0.03).round());
    final frameMarginY = math.max(2, (source.rows * 0.03).round());
    final touchesLeft = candidate.left <= frameMarginX;
    final touchesTop = candidate.top <= frameMarginY;
    final touchesRight = candidate.right >= source.cols - frameMarginX;
    final touchesBottom = candidate.bottom >= source.rows - frameMarginY;
    final touchedEdges = <bool>[
      touchesLeft,
      touchesTop,
      touchesRight,
      touchesBottom,
    ].where((value) => value).length;

    // A large contour touching multiple frame edges is normally the capture
    // sheet/background, not a credential. A4 bypasses this entire profile.
    // In multi-document mode a large contour touching two or more frame
    // edges is a sheet/background proposal, never an individual credential.
    // Specialist housing candidates are inserted separately and do not pass
    // through this generic geometric filter.
    if (areaRatio > 0.30 && touchedEdges >= 2) return false;
    // Keep borderline regions alive for manual review. The final automatic
    // acceptance decision is made per candidate by _candidateQuality.
    if (candidate.confidence < 0.42) return false;
  }

  if (profile.type == DocumentType.passport) {
    // A passport page should not be accepted as a tiny inner rectangle. The
    // full-frame fallback is considered later when only such candidates exist.
    // A face/photo rectangle is usually much smaller than the complete page.
    // Requiring meaningful page coverage prevents it from becoming the only
    // passport crop and allows the full-frame fallback to activate.
    if (areaRatio < 0.35) return false;
  }

  return true;
}

/// Expands a rectangle outward by [fraction] of its own size, clamped to the
/// image bounds and never exceeding [maxFraction] in a single direction. This
/// keeps the stamp-based housing-card expansion predictable when the green
/// seal sits close to the card border.
(int x, int y, int w, int h) _expandRect({
  required int x,
  required int y,
  required int w,
  required int h,
  required int rows,
  required int cols,
  required double fraction,
  double maxFraction = 0.35,
}) {
  final clampedFraction = math.min(fraction, maxFraction);
  final dx = (w * clampedFraction).round();
  final dy = (h * clampedFraction).round();
  final nx = math.max(0, x - dx);
  final ny = math.max(0, y - dy);
  final nx2 = math.min(cols, nx + w + 2 * dx);
  final ny2 = math.min(rows, ny + h + 2 * dy);
  return (nx, ny, nx2 - nx, ny2 - ny);
}

/// Measures how much of its convex hull a contour fills. A low value means the
/// blob is a sparse stroke collection rather than a solid stamp region.
double _contourSolidity(cv.VecPoint contour) {
  // cv.convexHull returns a Mat of type CV_32SC2 holding the hull points;
  // toList() exposes one row per point with [x, y], from which we build an
  // owned VecPoint for the area measurement.
  cv.Mat? hullMat;
  cv.VecPoint? hull;
  try {
    hullMat = cv.convexHull(contour);
    final hullPoints = hullMat.toList().cast<List<double>>();
    if (hullPoints.length < 3) return 0;
    hull = cv.VecPoint.fromList(
      hullPoints
          .map((point) => cv.Point(point[0].round(), point[1].round()))
          .toList(growable: false),
    );
    final hullArea = cv.contourArea(hull);
    return hullArea > 0 ? cv.contourArea(contour) / hullArea : 0;
  } finally {
    hull?.dispose();
    hullMat?.dispose();
  }
}

double _housingAnchorEvidence({
  required cv.Mat source,
  required cv.Rect bounds,
  required double contourArea,
}) {
  cv.Mat? roi;
  cv.Mat? hsv;
  cv.Mat? strictGreen;
  cv.Mat? relaxedGreen;
  cv.Mat? combinedGreen;
  cv.Scalar? hsvAverage;
  try {
    final boundingArea = math.max(1, bounds.width * bounds.height).toDouble();
    final fillRatio = (contourArea / boundingArea).clamp(0.0, 1.0).toDouble();
    roi = source.region(bounds);
    hsv = cv.cvtColor(roi, cv.COLOR_BGR2HSV);
    hsvAverage = hsv.mean();

    // Use two green ranges: the strict range rejects pale background noise,
    // while the relaxed range recovers a seal affected by glare or exposure.
    // The relaxed range is only supporting evidence; it cannot accept a crop
    // without the compact contour and outer-boundary checks.
    strictGreen = cv.inRangebyScalar(
      hsv,
      cv.Scalar(32, 48, 35),
      cv.Scalar(88, 255, 255),
    );
    relaxedGreen = cv.inRangebyScalar(
      hsv,
      cv.Scalar(25, 24, 24),
      cv.Scalar(96, 255, 255),
    );
    combinedGreen = cv.bitwiseOR(strictGreen, relaxedGreen);

    final roiArea = math.max(1, roi.rows * roi.cols).toDouble();
    final strictCoverage = (cv.countNonZero(strictGreen) / roiArea)
        .clamp(0.0, 1.0)
        .toDouble();
    final combinedCoverage = (cv.countNonZero(combinedGreen) / roiArea)
        .clamp(0.0, 1.0)
        .toDouble();
    final saturationScore = ((hsvAverage.val1 - 35) / 110)
        .clamp(0.0, 1.0)
        .toDouble();
    final brightnessScore = ((hsvAverage.val2 - 35) / 150)
        .clamp(0.0, 1.0)
        .toDouble();
    final strictCoverageScore = ((strictCoverage - 0.025) / 0.30)
        .clamp(0.0, 1.0)
        .toDouble();
    final coverageScore = ((combinedCoverage - 0.04) / 0.42)
        .clamp(0.0, 1.0)
        .toDouble();
    final fillScore = ((fillRatio - 0.24) / 0.46).clamp(0.0, 1.0).toDouble();

    return (strictCoverageScore * 0.35 +
            coverageScore * 0.20 +
            saturationScore * 0.15 +
            brightnessScore * 0.10 +
            fillScore * 0.20)
        .clamp(0.0, 1.0)
        .toDouble();
  } finally {
    hsvAverage?.dispose();
    combinedGreen?.dispose();
    relaxedGreen?.dispose();
    strictGreen?.dispose();
    hsv?.dispose();
    roi?.dispose();
  }
}

/// Stamp-based housing-card detection.
///
/// Classical edge masks fail on housing-card photos: the card rides in a
/// glossy plastic sleeve on a low-contrast surface, so only high-contrast
/// inner details (the portrait, text panels) ever become real contours —
/// which is exactly how the detector cropped a face instead of the card.
/// The round green ministry seal in the middle of every housing form is the
/// most reliable anchor. This builds a strict green mask, closes the seal
/// into a single blob with a large elliptical kernel, then expands the seal
/// bounding box outward using boundary evidence to recover the full card.
Future<List<_DocumentCandidate>> _housingCardStampCandidates({
  required cv.Mat source,
  required double imageArea,
  required _DocumentDetectionProfile profile,
  required bool Function() isCancelled,
}) async {
  cv.Mat? hsv;
  cv.Mat? strictSealMask;
  cv.Mat? relaxedSealMask;
  cv.Mat? sealMask;
  cv.Mat? sealKernel;
  cv.Mat? sealClosed;
  cv.VecVecPoint? contours;
  cv.VecVec4i? hierarchy;
  final candidates = <_DocumentCandidate>[];
  try {
    hsv = cv.cvtColor(source, cv.COLOR_BGR2HSV);
    strictSealMask = cv.inRangebyScalar(
      hsv,
      cv.Scalar(32, 48, 35),
      cv.Scalar(88, 255, 255),
    );
    relaxedSealMask = cv.inRangebyScalar(
      hsv,
      cv.Scalar(25, 24, 24),
      cv.Scalar(96, 255, 255),
    );
    sealMask = cv.bitwiseOR(strictSealMask, relaxedSealMask);
    sealKernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (51, 51));
    sealClosed = cv.morphologyEx(sealMask, cv.MORPH_CLOSE, sealKernel);
    final result = cv.findContours(
      sealClosed,
      cv.RETR_EXTERNAL,
      cv.CHAIN_APPROX_SIMPLE,
    );
    contours = result.$1;
    hierarchy = result.$2;
    var inspected = 0;
    for (final contour in contours) {
      if (isCancelled()) return candidates;
      if (inspected++ % 24 == 0) await Future<void>.delayed(Duration.zero);
      final contourArea = cv.contourArea(contour);
      // A housing page can occupy only a few percent of a multi-document
      // frame, and the green seal may be fragmented by glare. This is an
      // anchor gate, never a final crop gate: the expanded candidate still
      // has to pass page geometry and boundary/content scoring.
      if (contourArea < imageArea * 0.0025) continue;
      if (_contourSolidity(contour) < 0.24) continue;
      final bounds = cv.boundingRect(contour);
      try {
        final (bx, by, bw, bh) = _expandRect(
          x: bounds.x,
          y: bounds.y,
          w: bounds.width,
          h: bounds.height,
          rows: source.rows,
          cols: source.cols,
          fraction: 0.18,
        );
        final width = bw.toDouble();
        final height = bh.toDouble();
        if (width < 64 || height < 64) continue;
        final anchorRatio = math.max(width, height) / math.min(width, height);
        if (anchorRatio < 1.0 || anchorRatio > 2.4) continue;
        final boundingArea = width * height;
        final areaRatio = boundingArea / imageArea;
        if (areaRatio < 0.01 || areaRatio > 0.98) continue;
        final anchorEvidence = _housingAnchorEvidence(
          source: source,
          bounds: bounds,
          contourArea: contourArea,
        );
        if (anchorEvidence < 0.35 && areaRatio < 0.02) continue;
        final anchor = _DocumentCandidate(
          points: <cv.Point>[
            cv.Point(bx.toInt(), by.toInt()),
            cv.Point(bx.toInt() + width.toInt(), by.toInt()),
            cv.Point(bx.toInt() + width.toInt(), by.toInt() + height.toInt()),
            cv.Point(bx.toInt(), by.toInt() + height.toInt()),
          ],
          area: boundingArea,
          width: width.toDouble(),
          height: height.toDouble(),
          left: bx.toInt(),
          top: by.toInt(),
          right: bx.toInt() + width.toInt(),
          bottom: by.toInt() + height.toInt(),
          confidence: 0.84 + anchorEvidence * 0.11,
          documentEvidence: anchorEvidence,
          detectedType: DocumentType.housingCard,
        );
        // When one large green anchor occupies the centre of the frame, the
        // page itself is usually the complete capture and its outer border is
        // intentionally low contrast. In that case, expanding the HSV blob
        // is unsafe because the blob also contains green printed areas. Use a
        // conservative full-frame candidate rather than cutting into the page.
        final singlePageFallback = _fullFrameHousingCandidate(
          source: source,
          anchor: anchor,
          imageArea: imageArea,
        );
        if (singlePageFallback != null) {
          candidates.add(singlePageFallback);
          continue;
        }

        final boundaryCandidates = await _housingCardBoundaryCandidates(
          source: source,
          anchor: anchor,
          imageArea: imageArea,
          isCancelled: isCancelled,
        );
        if (isCancelled()) return candidates;
        if (boundaryCandidates.isNotEmpty) {
          candidates.addAll(boundaryCandidates);
        } else {
          candidates.add(anchor);
        }
      } finally {
        bounds.dispose();
      }
    }
  } finally {
    contours?.dispose();
    hierarchy?.dispose();
    sealClosed?.dispose();
    sealKernel?.dispose();
    sealMask?.dispose();
    relaxedSealMask?.dispose();
    strictSealMask?.dispose();
    hsv?.dispose();
  }
  return candidates;
}

_DocumentCandidate? _fullFrameHousingCandidate({
  required cv.Mat source,
  required _DocumentCandidate anchor,
  required double imageArea,
}) {
  final anchorWidthRatio = anchor.width / math.max(1, source.cols);
  final anchorHeightRatio = anchor.height / math.max(1, source.rows);
  if (anchorWidthRatio < 0.50 || anchorHeightRatio < 0.50) return null;

  const marginFraction = 0.01;
  final margin = (math.min(source.cols, source.rows) * marginFraction).round();
  final left = margin;
  final top = margin;
  final right = math.max(left + 1, source.cols - margin);
  final bottom = math.max(top + 1, source.rows - margin);
  final width = right - left;
  final height = bottom - top;
  final area = width * height.toDouble();
  final areaRatio = area / imageArea;
  final ratio = math.max(width, height) / math.max(1, math.min(width, height));
  if (areaRatio > 0.99 || ratio > 2.4) return null;

  return _DocumentCandidate(
    points: <cv.Point>[
      cv.Point(left, top),
      cv.Point(right, top),
      cv.Point(right, bottom),
      cv.Point(left, bottom),
    ],
    area: area,
    width: width.toDouble(),
    height: height.toDouble(),
    left: left,
    top: top,
    right: right,
    bottom: bottom,
    // This is a deliberate, type-specific fallback supported by a large
    // unique anchor. It is lower than a verified four-edge rectangle but
    // high enough to avoid a destructive face/logo crop.
    confidence: 0.87,
    detectedType: DocumentType.housingCard,
  );
}

Future<List<_DocumentCandidate>> _housingCardBoundaryCandidates({
  required cv.Mat source,
  required _DocumentCandidate anchor,
  required double imageArea,
  required bool Function() isCancelled,
}) async {
  cv.Mat? gray;
  cv.Mat? blurred;
  cv.Mat? edges;
  cv.Mat? kernel;
  cv.Mat? closed;
  cv.VecVecPoint? contours;
  cv.VecVec4i? hierarchy;
  try {
    gray = cv.cvtColor(source, cv.COLOR_BGR2GRAY);
    blurred = cv.gaussianBlur(gray, (5, 5), 0);
    edges = cv.canny(blurred, 18, 72);
    kernel = cv.getStructuringElement(cv.MORPH_RECT, (11, 11));
    closed = cv.morphologyEx(edges, cv.MORPH_CLOSE, kernel);
    final result = cv.findContours(
      closed,
      cv.RETR_EXTERNAL,
      cv.CHAIN_APPROX_SIMPLE,
    );
    contours = result.$1;
    hierarchy = result.$2;

    const boundaryProfile = _DocumentDetectionProfile(
      type: DocumentType.housingCard,
      minimumLongToShortRatio: 1.0,
      maximumLongToShortRatio: 2.4,
      minimumAreaRatio: 0.02,
      maximumAreaRatio: 0.98,
    );
    final linePage = _housingPageCandidateFromLines(
      edgeImage: closed,
      anchor: anchor,
      imageArea: imageArea,
    );
    if (linePage != null && linePage.confidence >= 0.79) {
      return <_DocumentCandidate>[linePage];
    }

    final anchorPage = _housingPageCandidateAroundAnchor(
      edgeImage: closed,
      anchor: anchor,
      imageArea: imageArea,
    );
    // A weak edge pattern often describes the camera frame or a plastic sleeve,
    // not the document. Keep the grid proposal only when all four borders
    // provide enough evidence; otherwise continue with the contour and anchor
    // fallbacks below.
    if (anchorPage != null && anchorPage.confidence >= 0.79) {
      return <_DocumentCandidate>[anchorPage];
    }

    final anchorWidth = math.max(1, anchor.width);
    final anchorHeight = math.max(1, anchor.height);
    final containing = <_DocumentCandidate>[];
    var inspected = 0;
    for (final contour in contours) {
      if (isCancelled()) return const <_DocumentCandidate>[];
      if (inspected++ % 24 == 0) await Future<void>.delayed(Duration.zero);
      final candidate = _candidateFromContour(
        contour,
        imageArea: imageArea,
        profile: boundaryProfile,
        allowAxisAlignedFallback: true,
      );
      if (candidate == null) continue;
      final containsAnchor =
          candidate.left <= anchor.centerX &&
          candidate.right >= anchor.centerX &&
          candidate.top <= anchor.centerY &&
          candidate.bottom >= anchor.centerY;
      if (!containsAnchor ||
          candidate.width < anchorWidth * 1.20 ||
          candidate.height < anchorHeight * 1.20 ||
          candidate.area < anchor.area * 1.35) {
        continue;
      }
      containing.add(candidate);
    }
    containing.sort((first, second) => first.area.compareTo(second.area));
    return containing.take(2).toList(growable: false);
  } finally {
    hierarchy?.dispose();
    contours?.dispose();
    closed?.dispose();
    kernel?.dispose();
    edges?.dispose();
    blurred?.dispose();
    gray?.dispose();
  }
}

_DocumentCandidate? _housingPageCandidateFromLines({
  required cv.Mat edgeImage,
  required _DocumentCandidate anchor,
  required double imageArea,
}) {
  cv.Mat? lines;
  try {
    final minimumDimension = math
        .min(edgeImage.cols, edgeImage.rows)
        .toDouble();
    lines = cv.HoughLinesP(
      edgeImage,
      1,
      cv.CV_PI / 180,
      math.max(24, (minimumDimension * 0.035).round()),
      minLineLength: minimumDimension * 0.22,
      maxLineGap: minimumDimension * 0.04,
    );
    final rows = lines.toList();
    final horizontal = <(double, double, double)>[];
    final vertical = <(double, double, double)>[];
    final angleTolerance = math.max(8.0, minimumDimension * 0.012);
    for (final row in rows) {
      if (row.length < 4) continue;
      final x1 = row[0].toDouble();
      final y1 = row[1].toDouble();
      final x2 = row[2].toDouble();
      final y2 = row[3].toDouble();
      final length = math.sqrt(math.pow(x2 - x1, 2) + math.pow(y2 - y1, 2));
      if (length < minimumDimension * 0.18) continue;
      final dx = (x2 - x1).abs();
      final dy = (y2 - y1).abs();
      if (dy <= angleTolerance &&
          math.max(x1, x2) >= anchor.left &&
          math.min(x1, x2) <= anchor.right) {
        horizontal.add(((y1 + y2) / 2, length, math.min(x1, x2)));
      } else if (dx <= angleTolerance &&
          math.max(y1, y2) >= anchor.top &&
          math.min(y1, y2) <= anchor.bottom) {
        vertical.add(((x1 + x2) / 2, length, math.min(y1, y2)));
      }
    }
    if (horizontal.length < 2 || vertical.length < 2) {
      return null;
    }

    final topLines = horizontal
        .where((line) => line.$1 < anchor.centerY)
        .toList();
    final bottomLines = horizontal
        .where((line) => line.$1 > anchor.centerY)
        .toList();
    final leftLines = vertical
        .where((line) => line.$1 < anchor.centerX)
        .toList();
    final rightLines = vertical
        .where((line) => line.$1 > anchor.centerX)
        .toList();
    if (topLines.isEmpty ||
        bottomLines.isEmpty ||
        leftLines.isEmpty ||
        rightLines.isEmpty) {
      return null;
    }

    // Select the strongest line on each side, while requiring a meaningful
    // distance from the anchor so inner text strokes cannot form a rectangle.
    double chooseSide(
      List<(double, double, double)> values,
      double center,
      bool isBefore,
    ) {
      values.sort((a, b) => b.$2.compareTo(a.$2));
      final eligible = values.where((line) {
        final distance = (line.$1 - center).abs();
        return distance >= math.min(anchor.width, anchor.height) * 0.35 &&
            distance <= math.max(anchor.width, anchor.height) * 3.2;
      }).toList();
      final source = eligible.isNotEmpty ? eligible : values;
      source.sort(
        (a, b) => isBefore ? a.$1.compareTo(b.$1) : b.$1.compareTo(a.$1),
      );
      return source.first.$1;
    }

    final top = chooseSide(topLines, anchor.centerY, true);
    final bottom = chooseSide(bottomLines, anchor.centerY, false);
    final left = chooseSide(leftLines, anchor.centerX, true);
    final right = chooseSide(rightLines, anchor.centerX, false);
    final width = right - left;
    final height = bottom - top;
    if (width < anchor.width * 1.25 || height < anchor.height * 1.25) {
      return null;
    }
    if (width <= 0 || height <= 0) {
      return null;
    }
    final ratio = math.max(width, height) / math.min(width, height);
    if (ratio < 1.0 || ratio > 2.4) {
      return null;
    }
    final area = width * height;
    final areaRatio = area / imageArea;
    // A Hough rectangle covering most of a multi-document frame is usually
    // a shared background edge or two adjacent pages, not one housing card.
    // Large single-page captures are handled by the type-specific full-frame
    // fallback before this method is called.
    if (areaRatio < 0.02 || areaRatio > 0.45) return null;

    final leftInt = _clampInt(left.round(), 0, edgeImage.cols - 1);
    final topInt = _clampInt(top.round(), 0, edgeImage.rows - 1);
    final rightInt = _clampInt(right.round(), leftInt + 1, edgeImage.cols);
    final bottomInt = _clampInt(bottom.round(), topInt + 1, edgeImage.rows);
    final candidateWidth = rightInt - leftInt;
    final candidateHeight = bottomInt - topInt;
    final sizeScore = (areaRatio / 0.28).clamp(0.0, 1.0).toDouble();
    final ratioScore = (1 - ((ratio - 1.55).abs() / 0.9))
        .clamp(0.0, 1.0)
        .toDouble();
    final confidence = (0.58 + sizeScore * 0.20 + ratioScore * 0.17)
        .clamp(0.0, 0.95)
        .toDouble();
    return _DocumentCandidate(
      points: <cv.Point>[
        cv.Point(leftInt, topInt),
        cv.Point(rightInt, topInt),
        cv.Point(rightInt, bottomInt),
        cv.Point(leftInt, bottomInt),
      ],
      area: candidateWidth * candidateHeight.toDouble(),
      width: candidateWidth.toDouble(),
      height: candidateHeight.toDouble(),
      left: leftInt,
      top: topInt,
      right: rightInt,
      bottom: bottomInt,
      confidence: confidence,
      detectedType: DocumentType.housingCard,
    );
  } finally {
    lines?.dispose();
  }
}

_DocumentCandidate? _housingPageCandidateAroundAnchor({
  required cv.Mat edgeImage,
  required _DocumentCandidate anchor,
  required double imageArea,
}) {
  final centerX = anchor.centerX;
  final centerY = anchor.centerY;
  final anchorWidth = math.max(1.0, anchor.width);
  final anchorHeight = math.max(1.0, anchor.height);
  // The first factors preserve a close-up seal candidate; the larger factors
  // recover a full housing form when only its central seal survives the color
  // mask. A bounded search is safer than blindly expanding to the frame.
  const widthFactors = <double>[
    1.3,
    1.5,
    1.7,
    2.0,
    2.3,
    2.6,
    3.0,
    3.5,
    4.0,
    4.6,
    5.2,
  ];
  const heightFactors = <double>[
    1.15,
    1.3,
    1.5,
    1.7,
    1.9,
    2.15,
    2.4,
    2.8,
    3.2,
    3.7,
  ];
  _DocumentCandidate? best;
  var bestScore = 0.0;

  double maskDensity(cv.Rect rect) {
    cv.Mat? roi;
    try {
      roi = edgeImage.region(rect);
      final area = math.max(1, rect.width * rect.height);
      return cv.countNonZero(roi) / area;
    } finally {
      roi?.dispose();
    }
  }

  for (final widthFactor in widthFactors) {
    for (final heightFactor in heightFactors) {
      final width = (anchorWidth * widthFactor).round();
      final height = (anchorHeight * heightFactor).round();
      if (width < 96 || height < 96) continue;
      var left = (centerX - width / 2).round();
      var top = (centerY - height / 2).round();
      left = _clampInt(left, 0, edgeImage.cols - 1);
      top = _clampInt(top, 0, edgeImage.rows - 1);
      final right = _clampInt(left + width, left + 1, edgeImage.cols);
      final bottom = _clampInt(top + height, top + 1, edgeImage.rows);
      final actualWidth = right - left;
      final actualHeight = bottom - top;
      final area = actualWidth * actualHeight.toDouble();
      final areaRatio = area / imageArea;
      if (areaRatio < 0.012 || areaRatio > 0.72) continue;
      final ratio =
          math.max(actualWidth, actualHeight) /
          math.max(1, math.min(actualWidth, actualHeight));
      if (ratio < 1.0 || ratio > 2.4) continue;

      final thickness = math.max(3, math.min(actualWidth, actualHeight) ~/ 60);
      final topDensity = maskDensity(
        cv.Rect(left, top, actualWidth, math.min(thickness, actualHeight)),
      );
      final bottomDensity = maskDensity(
        cv.Rect(
          left,
          math.max(top, bottom - thickness),
          actualWidth,
          math.min(thickness, actualHeight),
        ),
      );
      final leftDensity = maskDensity(
        cv.Rect(left, top, math.min(thickness, actualWidth), actualHeight),
      );
      final rightDensity = maskDensity(
        cv.Rect(
          math.max(left, right - thickness),
          top,
          math.min(thickness, actualWidth),
          actualHeight,
        ),
      );
      final edgeSupport = math.min(
        math.min(topDensity, bottomDensity),
        math.min(leftDensity, rightDensity),
      );
      if (edgeSupport < 0.004) continue;

      final innerLeft = _clampInt(left + thickness, left, right - 1);
      final innerTop = _clampInt(top + thickness, top, bottom - 1);
      final innerRight = _clampInt(right - thickness, innerLeft + 1, right);
      final innerBottom = _clampInt(bottom - thickness, innerTop + 1, bottom);
      final interiorDensity = maskDensity(
        cv.Rect(
          innerLeft,
          innerTop,
          math.max(1, innerRight - innerLeft),
          math.max(1, innerBottom - innerTop),
        ),
      );
      final ratioScore = (1 - ((ratio - 1.55).abs() / 0.9))
          .clamp(0.0, 1.0)
          .toDouble();
      final borderScore = (edgeSupport / 0.12).clamp(0.0, 1.0).toDouble();
      final contentScore = (1 - ((interiorDensity - 0.12).abs() / 0.20))
          .clamp(0.0, 1.0)
          .toDouble();
      final score =
          borderScore * 0.60 + ratioScore * 0.25 + contentScore * 0.15;
      if (score <= bestScore) continue;
      bestScore = score;
      best = _DocumentCandidate(
        points: <cv.Point>[
          cv.Point(left, top),
          cv.Point(right, top),
          cv.Point(right, bottom),
          cv.Point(left, bottom),
        ],
        area: area,
        width: actualWidth.toDouble(),
        height: actualHeight.toDouble(),
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        confidence: (0.60 + score * 0.35).clamp(0.0, 0.95).toDouble(),
        detectedType: DocumentType.housingCard,
      );
    }
  }
  return best;
}

/// Full-frame passport fallback.
///
/// Some passport captures are flat scans with the page covering almost the
/// entire frame and no detectable outer border at all. When every geometric
/// mask fails to produce a candidate, the only faithful crop is the frame
/// itself, trimmed inward by a small margin to avoid scan edge artefacts.
_DocumentCandidate? _fullFrameCandidateForPassport({
  required cv.Mat source,
  required _DocumentDetectionProfile profile,
}) {
  const marginFraction = 0.02;
  final rows = source.rows.toDouble();
  final cols = source.cols.toDouble();
  final margin = math.min(cols, rows) * marginFraction;
  final left = margin;
  final top = margin;
  final width = cols - 2 * margin;
  final height = rows - 2 * margin;
  if (width < 64 || height < 64) return null;
  if (!profile.acceptsAspectRatio(width, height)) return null;
  final boundingArea = width * height;
  if (!profile.acceptsArea(boundingArea, rows * cols)) return null;
  final leftInt = left.round();
  final topInt = top.round();
  final widthInt = width.round();
  final heightInt = height.round();
  return _DocumentCandidate(
    points: <cv.Point>[
      cv.Point(leftInt, topInt),
      cv.Point(leftInt + widthInt, topInt),
      cv.Point(leftInt + widthInt, topInt + heightInt),
      cv.Point(leftInt, topInt + heightInt),
    ],
    area: boundingArea,
    width: widthInt.toDouble(),
    height: heightInt.toDouble(),
    left: leftInt,
    top: topInt,
    right: leftInt + widthInt,
    bottom: topInt + heightInt,
    confidence: 0.90,
    evidenceCount: 2,
    documentEvidence: 1.0,
    detectedType: DocumentType.passport,
  );
}

const _stageBudgets = <String, Duration>{
  'decode': Duration(seconds: 4),
  'resize': Duration(seconds: 3),
  'preprocessing': Duration(seconds: 5),
  'detection': Duration(seconds: 8),
  'warp_write': Duration(seconds: 10),
};

_SmartCropOutput? _stageTimeoutResult(String stage, Stopwatch watch) {
  final budget = _stageBudgets[stage];
  if (budget == null || watch.elapsed <= budget) return null;
  return _SmartCropOutput(
    paths: const <String>[],
    confidence: 0,
    detectedDocumentCount: 0,
    reviewReason:
        'تجاوزت مرحلة $stage المهلة المحددة وتحتاج الصورة إلى مراجعة يدوية.',
  );
}

Future<_SmartCropOutput> _detectAndCropInIsolate(
  Map<String, dynamic> args, {
  bool Function()? isCancelled,
}) async {
  final imagePath = args['imagePath'] as String;
  final tempPath = args['tempPath'] as String;
  final jobId = args['jobId'] as String? ?? 'legacy';
  final detectionTypes = _detectionTypesFromArgs(args);
  final runGenericDetector = detectionTypes.any(
    (type) =>
        type == DocumentType.allDocuments ||
        type == DocumentType.nationalId ||
        type == DocumentType.rationCard,
  );
  final runHousingDetector = detectionTypes.contains(DocumentType.housingCard);
  final runGeometricDetector = runGenericDetector || runHousingDetector;
  final runPassportDetector = detectionTypes.contains(DocumentType.passport);
  final genericProfile = _detectionProfileFor(
    detectionTypes.length > 1
        ? DocumentType.allDocuments
        : detectionTypes.first,
  );
  final passportProfile = _detectionProfileFor(DocumentType.passport);
  if (isCancelled?.call() ?? false) {
    return const _SmartCropOutput(
      paths: <String>[],
      confidence: 0,
      detectedDocumentCount: 0,
      reviewReason: 'ألغيت المعالجة قبل بدء الكشف.',
    );
  }
  if (detectionTypes.length == 1 &&
      detectionTypes.first == DocumentType.a4Document) {
    return _SmartCropOutput(
      paths: <String>[imagePath],
      confidence: 1,
      detectedDocumentCount: 1,
      reviewReason: '',
    );
  }
  cv.Mat? source;
  cv.Mat? analysisSource;
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
  cv.Mat? hsv;
  cv.Mat? saturated;
  cv.Mat? saturatedClosed;
  cv.Mat? saturatedOpen;
  cv.Mat? foreground;
  cv.Mat? foregroundClosed;
  cv.Mat? kernel;
  cv.Mat? broadKernel;
  cv.Mat? foregroundKernel;
  var candidates = <_DocumentCandidate>[];
  var sourceWidth = 0;
  var sourceHeight = 0;
  var analysisWidth = 0;
  var analysisHeight = 0;
  // Keep geometrically plausible proposals that fail only a visual/type gate.
  // They must remain available for manual review instead of disappearing before
  // the UI can offer a boundary suggestion.
  var reviewProposals = <_DocumentCandidate>[];
  final results = <String>[];
  var reviewCandidates = const <_DocumentCandidate>[];
  var acceptedCandidates = const <_DocumentCandidate>[];
  final stageMilliseconds = <String, int>{};
  var peakMemoryBytes = ProcessInfo.currentRss;
  void recordStage(String name, Stopwatch stopwatch) {
    stageMilliseconds[name] = stopwatch.elapsedMilliseconds;
    peakMemoryBytes = math.max(peakMemoryBytes, ProcessInfo.currentRss);
  }

  Future<bool> collectCandidates(
    cv.Mat image,
    double imageArea, {
    required _DocumentDetectionProfile profile,
    int retrievalMode = cv.RETR_EXTERNAL,
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
        final rawCandidate = _candidateFromContour(
          contour,
          imageArea: imageArea,
          profile: profile,
          allowAxisAlignedFallback: allowAxisAlignedFallback,
        );
        if (rawCandidate == null) continue;
        final candidate = profile.type == DocumentType.passport && gray != null
            ? rawCandidate.copyWith(
                documentEvidence: _passportMrzEvidence(
                  gray: gray,
                  candidate: rawCandidate,
                ),
                detectedType: DocumentType.passport,
              )
            : rawCandidate.copyWith(detectedType: profile.type);
        final passesGeometryGate = _isLikelyDocumentCandidate(
          source: image,
          candidate: candidate,
          profile: profile,
        );
        final passesVisualGate = _matchesVisualProfile(
          analysisSource!,
          candidate,
          profile,
        );
        if (!passesGeometryGate) continue;
        if (!passesVisualGate) {
          // A visually ambiguous but geometrically credible region is exactly
          // what the manual crop screen needs. Do not silently discard it.
          _mergeCandidate(reviewProposals, candidate);
          continue;
        }
        _mergeCandidate(candidates, candidate);
      }
      return !(isCancelled?.call() ?? false);
    } finally {
      contours.dispose();
      hierarchy.dispose();
    }
  }

  try {
    final decodeWatch = Stopwatch()..start();
    source = cv.imdecode(File(imagePath).readAsBytesSync(), cv.IMREAD_COLOR);
    recordStage('decode', decodeWatch);
    final decodeTimeout = _stageTimeoutResult('decode', decodeWatch);
    if (decodeTimeout != null) return decodeTimeout;
    if (source.isEmpty) {
      return const _SmartCropOutput(
        paths: <String>[],
        confidence: 0,
        detectedDocumentCount: 0,
        reviewReason: 'تعذر قراءة الصورة الأصلية.',
      );
    }

    // Keep the decoded source at its original resolution for the final warp.
    // All expensive vision operations run on a bounded analysis image, and
    // candidate coordinates are mapped back to the source before writing.
    sourceWidth = source.cols;
    sourceHeight = source.rows;
    const maximumAnalysisDimension = 1600;
    final resizeWatch = Stopwatch()..start();
    analysisSource = source;
    final largestDimension = math.max(source.cols, source.rows);
    if (largestDimension > maximumAnalysisDimension) {
      final scale = maximumAnalysisDimension / largestDimension;
      analysisSource = cv.resize(source, (0, 0), fx: scale, fy: scale);
    }
    analysisWidth = analysisSource.cols;
    analysisHeight = analysisSource.rows;
    recordStage('resize', resizeWatch);
    final resizeTimeout = _stageTimeoutResult('resize', resizeWatch);
    if (resizeTimeout != null) return resizeTimeout;

    final preprocessingWatch = Stopwatch()..start();
    gray = cv.cvtColor(analysisSource, cv.COLOR_BGR2GRAY);
    blurred = cv.gaussianBlur(gray, (5, 5), 0);
    kernel = cv.getStructuringElement(cv.MORPH_RECT, (7, 7));
    broadKernel = cv.getStructuringElement(cv.MORPH_RECT, (11, 11));
    foregroundKernel = cv.getStructuringElement(cv.MORPH_RECT, (5, 5));
    // Housing cards are handled through a dedicated stamp-anchored path.
    // Their glossy plastic sleeves suppress every outer edge, so the round
    // green ministry seal is used as the reliable anchor and expanded into
    // the full card extent instead of proposing geometric quadrilaterals.
    // In allDocuments mode the same specialist path is merged with the
    // geometric card proposals, so the green housing card is not lost.
    recordStage('preprocessing', preprocessingWatch);
    final preprocessingTimeout = _stageTimeoutResult(
      'preprocessing',
      preprocessingWatch,
    );
    if (preprocessingTimeout != null) return preprocessingTimeout;
    final detectionWatch = Stopwatch()..start();
    if (runHousingDetector) {
      final housingProfile = _detectionProfileFor(DocumentType.housingCard);
      final stampCandidates = await _housingCardStampCandidates(
        source: analysisSource,
        imageArea: (analysisSource.rows * analysisSource.cols).toDouble(),
        profile: housingProfile,
        isCancelled: isCancelled ?? (() => false),
      );
      if (isCancelled?.call() ?? false) {
        return const _SmartCropOutput(
          paths: <String>[],
          confidence: 0,
          detectedDocumentCount: 0,
          reviewReason: 'ألغيت المعالجة أثناء كشف بطاقة السكن.',
        );
      }
      for (final candidate in stampCandidates) {
        _mergeCandidate(candidates, candidate);
      }
    }
    if (runGeometricDetector || runPassportDetector) {
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
      final imageArea = (analysisSource.rows * analysisSource.cols).toDouble();

      // A saturation proposal is the reliable multi-document path for the
      // blue/lilac unified cards in a light sheet. It produces one external
      // component per card in both portrait and landscape captures, while the
      // green-tint gate excludes the housing form from the national-ID type.
      if (detectionTypes.contains(DocumentType.nationalId) ||
          detectionTypes.contains(DocumentType.allDocuments)) {
        hsv = cv.cvtColor(analysisSource, cv.COLOR_BGR2HSV);
        final saturationLower = cv.Scalar(0, 35, 50);
        final saturationUpper = cv.Scalar(179, 255, 255);
        try {
          saturated = cv.inRangebyScalar(hsv, saturationLower, saturationUpper);
        } finally {
          saturationUpper.dispose();
          saturationLower.dispose();
        }
        final saturationKernel = cv.getStructuringElement(cv.MORPH_RECT, (
          11,
          11,
        ));
        try {
          saturatedClosed = cv.morphologyEx(
            saturated,
            cv.MORPH_CLOSE,
            saturationKernel,
          );
        } finally {
          saturationKernel.dispose();
        }
        final saturationOpenKernel = cv.getStructuringElement(cv.MORPH_RECT, (
          5,
          5,
        ));
        try {
          saturatedOpen = cv.morphologyEx(
            saturatedClosed,
            cv.MORPH_OPEN,
            saturationOpenKernel,
          );
        } finally {
          saturationOpenKernel.dispose();
        }
        if (!await collectCandidates(
          saturatedOpen,
          imageArea,
          profile: genericProfile,
          retrievalMode: cv.RETR_EXTERNAL,
          allowAxisAlignedFallback: true,
        )) {
          return const _SmartCropOutput(
            paths: <String>[],
            confidence: 0,
            detectedDocumentCount: 0,
            reviewReason: 'ألغيت المعالجة أثناء فصل البطاقات الملونة.',
          );
        }
      }

      if (runGeometricDetector &&
          (!await collectCandidates(
                edgeClosed,
                imageArea,
                profile: genericProfile,
              ) ||
              !await collectCandidates(
                sensitiveEdgeClosed,
                imageArea,
                profile: genericProfile,
              ) ||
              !await collectCandidates(
                thresholdClosed,
                imageArea,
                profile: genericProfile,
              ) ||
              !await collectCandidates(
                sensitiveThresholdClosed,
                imageArea,
                profile: genericProfile,
              ) ||
              !await collectCandidates(
                foregroundClosed,
                imageArea,
                profile: genericProfile,
                retrievalMode: cv.RETR_EXTERNAL,
                allowAxisAlignedFallback: true,
              ))) {
        return const _SmartCropOutput(
          paths: <String>[],
          confidence: 0,
          detectedDocumentCount: 0,
          reviewReason: 'لم يُعثر على حدود مستند موثوقة.',
        );
      }
      if (runPassportDetector &&
          (!await collectCandidates(
                edgeClosed,
                imageArea,
                profile: passportProfile,
              ) ||
              !await collectCandidates(
                sensitiveEdgeClosed,
                imageArea,
                profile: passportProfile,
              ) ||
              !await collectCandidates(
                thresholdClosed,
                imageArea,
                profile: passportProfile,
              ) ||
              !await collectCandidates(
                sensitiveThresholdClosed,
                imageArea,
                profile: passportProfile,
              ) ||
              !await collectCandidates(
                foregroundClosed,
                imageArea,
                profile: passportProfile,
                retrievalMode: cv.RETR_EXTERNAL,
                allowAxisAlignedFallback: true,
              ))) {
        return const _SmartCropOutput(
          paths: <String>[],
          confidence: 0,
          detectedDocumentCount: 0,
          reviewReason: 'ألغيت المعالجة أثناء تحليل صفحة الجواز.',
        );
      }
    }
    recordStage('detection', detectionWatch);
    final detectionTimeout = _stageTimeoutResult('detection', detectionWatch);
    if (detectionTimeout != null) return detectionTimeout;

    // A flat passport scan with no visible outer border produces no geometric
    // candidate at all. The full-frame fallback is the faithful crop in that
    // case: the document genuinely covers the whole frame.
    final hasPassportCandidate = candidates.any(
      (candidate) => candidate.detectedType == DocumentType.passport,
    );
    final isPassportOnlyRequest =
        detectionTypes.length == 1 &&
        detectionTypes.first == DocumentType.passport;
    if (runPassportDetector && isPassportOnlyRequest && !hasPassportCandidate) {
      final fullFrame = _fullFrameCandidateForPassport(
        source: analysisSource,
        profile: passportProfile,
      );
      if (fullFrame != null) candidates.add(fullFrame);
    }

    candidates = _selectDistinctCandidates(candidates);

    _DocumentDetectionProfile profileForCandidate(
      _DocumentCandidate candidate,
    ) => _detectionProfileFor(
      candidate.detectedType == DocumentType.unknown
          ? genericProfile.type
          : candidate.detectedType,
    );
    final lowConfidenceCandidates = candidates
        .where(
          (candidate) => !_isAutomaticallyAcceptable(
            candidate,
            profileForCandidate(candidate),
          ),
        )
        .toList(growable: false);
    final reviewPool = <_DocumentCandidate>[
      ...lowConfidenceCandidates,
      ...reviewProposals,
    ];
    reviewCandidates = _selectReviewCandidates(
      _selectDistinctCandidates(reviewPool),
      detectedDocumentCount: math.max(candidates.length, reviewPool.length),
    );
    acceptedCandidates = candidates
        .where(
          (candidate) => _isAutomaticallyAcceptable(
            candidate,
            profileForCandidate(candidate),
          ),
        )
        .toList(growable: false);

    final sourceScaleX = source.cols / analysisSource.cols;
    final sourceScaleY = source.rows / analysisSource.rows;
    final cropWatch = Stopwatch()..start();
    for (final candidate in acceptedCandidates) {
      final cropTimeout = _stageTimeoutResult('warp_write', cropWatch);
      if (cropTimeout != null) return cropTimeout;
      if (isCancelled?.call() ?? false) {
        return const _SmartCropOutput(
          paths: <String>[],
          confidence: 0,
          detectedDocumentCount: 0,
          reviewReason: 'ألغيت المعالجة أثناء القص.',
        );
      }
      cv.VecPoint? sourcePoints;
      cv.VecPoint? destinationPoints;
      cv.Mat? transform;
      cv.Mat? warped;
      try {
        final paddingX = math.max(1, (8 * sourceScaleX).round());
        final paddingY = math.max(1, (8 * sourceScaleY).round());
        int sourceX(num value) => (value * sourceScaleX).round();
        int sourceY(num value) => (value * sourceScaleY).round();
        final padded = <cv.Point>[
          cv.Point(
            _clampInt(
              sourceX(candidate.points[0].x) - paddingX,
              0,
              source.cols - 1,
            ),
            _clampInt(
              sourceY(candidate.points[0].y) - paddingY,
              0,
              source.rows - 1,
            ),
          ),
          cv.Point(
            _clampInt(
              sourceX(candidate.points[1].x) + paddingX,
              0,
              source.cols - 1,
            ),
            _clampInt(
              sourceY(candidate.points[1].y) - paddingY,
              0,
              source.rows - 1,
            ),
          ),
          cv.Point(
            _clampInt(
              sourceX(candidate.points[2].x) + paddingX,
              0,
              source.cols - 1,
            ),
            _clampInt(
              sourceY(candidate.points[2].y) + paddingY,
              0,
              source.rows - 1,
            ),
          ),
          cv.Point(
            _clampInt(
              sourceX(candidate.points[3].x) - paddingX,
              0,
              source.cols - 1,
            ),
            _clampInt(
              sourceY(candidate.points[3].y) + paddingY,
              0,
              source.rows - 1,
            ),
          ),
        ];
        final outputWidth = math.max(
          48,
          (candidate.width * sourceScaleX + paddingX * 2).round(),
        );
        final outputHeight = math.max(
          48,
          (candidate.height * sourceScaleY + paddingY * 2).round(),
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
    recordStage('warp_write', cropWatch);
    final warpTimeout = _stageTimeoutResult('warp_write', cropWatch);
    if (warpTimeout != null) return warpTimeout;
  } catch (error, stackTrace) {
    _logScannerError('smart-crop-output', error, stackTrace);
    return const _SmartCropOutput(
      paths: <String>[],
      confidence: 0,
      detectedDocumentCount: 0,
      reviewReason: 'تعذر إنشاء قص موثوق من الصورة.',
    );
  } finally {
    if (!identical(analysisSource, source)) {
      analysisSource?.dispose();
    }
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
    saturatedOpen?.dispose();
    saturatedClosed?.dispose();
    saturated?.dispose();
    hsv?.dispose();
    kernel?.dispose();
    broadKernel?.dispose();
    foregroundKernel?.dispose();
  }
  final acceptedQualityScores = acceptedCandidates
      .map(_candidateQuality)
      .toList(growable: false);
  final reviewQualityScores = reviewCandidates
      .map(_candidateQuality)
      .toList(growable: false);
  final cropConfidence = acceptedQualityScores.isNotEmpty
      ? acceptedQualityScores.reduce(math.min).clamp(0.0, 1.0).toDouble()
      : reviewQualityScores.isNotEmpty
      ? reviewQualityScores.reduce(math.max).clamp(0.0, 1.0).toDouble()
      : 0.0;
  final reviewRegions = scaleDocumentRegionsToSource(
    reviewCandidates.map((candidate) => candidate.region),
    analysisWidth: analysisWidth,
    analysisHeight: analysisHeight,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
  );
  final reviewReason = reviewRegions.isEmpty
      ? ''
      : 'تم قبول ${results.length} قص تلقائياً، وتحتاج ${reviewRegions.length} منطقة إلى مراجعة يدوية.';
  return _SmartCropOutput(
    paths: List<String>.unmodifiable(results),
    confidence: cropConfidence,
    detectedDocumentCount: math.max(candidates.length, reviewCandidates.length),
    reviewReason: reviewReason,
    reviewRegions: reviewRegions,
    performanceMetrics: ScanPerformanceMetrics(
      stageMilliseconds: Map<String, int>.unmodifiable(stageMilliseconds),
      peakMemoryBytes: peakMemoryBytes,
    ),
  );
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
  } catch (error, stackTrace) {
    _logScannerError('ocr-preprocess', error, stackTrace);
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
    final output = await _detectAndCropInIsolate(
      args,
      isCancelled: () => isCancelled,
    );
    resultPort.send(<String, Object?>{
      'type': isCancelled ? 'cancelled' : 'completed',
      'outputPaths': output.paths,
      'cropConfidence': output.confidence,
      'detectedDocumentCount': output.detectedDocumentCount,
      'cropReviewReason': output.reviewReason,
      'reviewRegions': output.reviewRegions
          .map(_documentRegionToMessage)
          .toList(growable: false),
      'performanceMetrics': _performanceMetricsToMessage(
        output.performanceMetrics,
      ),
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

  Future<_SmartCropOutput> _runSmartCropWorker({
    required File imageFile,
    required String tempPath,
    required String jobId,
    required DetectionPlan detectionPlan,
    required ScanCancellationToken token,
  }) async {
    if (token.isCancelled) throw const _ScanWorkerCancelled();

    final resultPort = ReceivePort();
    final completed = Completer<_SmartCropOutput>();
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
          final confidence =
              (message['cropConfidence'] as num?)?.toDouble() ??
              (paths.isEmpty ? 0.0 : 0.65);
          final detectedDocumentCount =
              (message['detectedDocumentCount'] as num?)?.toInt() ??
              paths.length;
          final reviewReason = message['cropReviewReason'] as String? ?? '';
          final reviewRegions =
              ((message['reviewRegions'] as List<Object?>?) ??
                      const <Object?>[])
                  .map(_documentRegionFromMessage)
                  .whereType<DocumentRegion>()
                  .toList(growable: false);
          final performanceMetrics = _performanceMetricsFromMessage(
            message['performanceMetrics'],
          );
          if (!completed.isCompleted) {
            completed.complete(
              _SmartCropOutput(
                paths: List<String>.unmodifiable(paths),
                confidence: confidence.clamp(0.0, 1.0).toDouble(),
                detectedDocumentCount: detectedDocumentCount,
                reviewReason: reviewReason,
                reviewRegions: List<DocumentRegion>.unmodifiable(reviewRegions),
                performanceMetrics: performanceMetrics,
              ),
            );
          }
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
          'documentTypeIndex': detectionPlan.types.first.index,
          'detectionTypeIndices': detectionPlan.typeIndices,
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

  DocumentClassification _classificationForPlan(DetectionPlan plan) {
    final type = plan.resultType;
    final reason = plan.contains(DocumentType.passport) && plan.types.length > 1
        ? 'تم تشغيل كاشف الجواز مع الكواشف الأخرى بشكل مستقل.'
        : type == DocumentType.allDocuments
        ? 'تم تشغيل كواشف المستندات المحددة بشكل مستقل داخل الصورة.'
        : 'تم اعتماد نوع المستند المحدد من إعدادات المستخدم.';
    return DocumentClassification(
      type: type,
      normalizedText: '',
      confidence: 1,
      reason: reason,
      requiresManualReview: false,
    );
  }

  Future<SmartScanResult> processSmartRecognition(
    File imageFile, {
    DocumentType? documentType,
    List<DocumentType>? detectionTypes,
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
    final detectionPlan = detectionTypes == null
        ? DetectionPlan.forType(requestedType)
        : DetectionPlan.forTypes(detectionTypes);
    if (detectionPlan.isA4Only) {
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
        classification: _classificationForPlan(detectionPlan),
        status: SmartScanStatus.succeeded,
        message: 'تم اعتماد الصورة كاملة كورقة A4.',
        cropConfidence: 1,
        detectedDocumentCount: 1,
      );
    }

    await TemporaryImageStore.cleanupStale();
    final tempDirectory = await getTemporaryDirectory();
    final jobId = DateTime.now().microsecondsSinceEpoch.toString();
    late final _SmartCropOutput cropOutput;
    try {
      cropOutput = await _runSmartCropWorker(
        imageFile: imageFile,
        tempPath: tempDirectory.path,
        jobId: jobId,
        detectionPlan: detectionPlan,
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
    } catch (error, stackTrace) {
      _logScannerError('smart-recognition', error, stackTrace);
      await TemporaryImageStore.deleteManagedWithMarker(jobId);
      return SmartScanResult(
        source: imageFile,
        files: const <File>[],
        classification: DocumentClassification.unknown,
        status: SmartScanStatus.manualReviewRequired,
        message: 'تعذر تحليل حدود المستند؛ يُرجى تحديده يدوياً.',
      );
    }

    final outputPaths = cropOutput.paths;
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
        message: cropOutput.reviewReason.isEmpty
            ? 'لم يُعثر على مستند موثوق؛ يُرجى تحديده يدوياً.'
            : cropOutput.reviewReason,
        cropConfidence: cropOutput.confidence,
        detectedDocumentCount: cropOutput.detectedDocumentCount,
        cropReviewReason: cropOutput.reviewReason,
        manualReviewRegions: cropOutput.reviewRegions,
        performanceMetrics: cropOutput.performanceMetrics,
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
      final shouldClassifyOutput = requestedType == DocumentType.unknown;
      classification = shouldClassifyOutput
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
          : _classificationForPlan(
              detectionTypes == null
                  ? DetectionPlan.forType(requestedType)
                  : detectionPlan,
            );
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
    final cropNeedsReview = cropOutput.reviewRegions.isNotEmpty;
    final status = classification.requiresManualReview || cropNeedsReview
        ? SmartScanStatus.manualReviewRequired
        : SmartScanStatus.succeeded;
    final reviewReason = cropNeedsReview
        ? (cropOutput.reviewReason.isEmpty
              ? 'تم قبول القصوص المؤكدة؛ راجع المناطق المحددة يدوياً.'
              : cropOutput.reviewReason)
        : '';
    return SmartScanResult(
      source: imageFile,
      files: files,
      classification: classification,
      status: status,
      message: classification.requiresManualReview || cropNeedsReview
          ? 'تم حفظ القصوص المؤكدة، وتحتاج بعض المناطق إلى مراجعة.'
          : 'اكتمل القص والتصنيف بثقة مناسبة.',
      cropConfidence: cropOutput.confidence,
      detectedDocumentCount: cropOutput.detectedDocumentCount,
      cropReviewReason: reviewReason,
      manualReviewRegions: cropOutput.reviewRegions,
      performanceMetrics: cropOutput.performanceMetrics,
    );
  }

  Future<SmartScanBatchResult> processBatchSmartRecognition(
    List<File> imageFiles, {
    DocumentType? documentType,
    List<DocumentType>? detectionTypes,
    void Function(int current, int total)? onProgress,
    ScanCancellationToken? cancellationToken,
  }) async {
    final activeToken = cancellationToken ?? ScanCancellationToken();
    final results = <File, SmartScanResult>{};
    var nextIndex = 0;
    var completedCount = 0;

    Future<void> runWorker() async {
      while (true) {
        if (activeToken.isCancelled) return;
        final index = nextIndex++;
        if (index >= imageFiles.length) return;
        final source = imageFiles[index];
        try {
          final result = await processSmartRecognition(
            source,
            documentType: documentType,
            detectionTypes: detectionTypes,
            cancellationToken: activeToken,
          );
          results[source] = result;
          if (result.status == SmartScanStatus.cancelled ||
              activeToken.isCancelled) {
            return;
          }
        } catch (error, stackTrace) {
          if (activeToken.isCancelled) return;
          _logScannerError('batch-smart-recognition', error, stackTrace);
          results[source] = SmartScanResult(
            source: source,
            files: const <File>[],
            classification: DocumentClassification.unknown,
            status: SmartScanStatus.failed,
            message: 'تعذرت معالجة هذه الصورة؛ يُرجى قصها يدوياً.',
          );
        }
        if (!activeToken.isCancelled) {
          completedCount++;
          onProgress?.call(completedCount, imageFiles.length);
        }
      }
    }

    final workerCount = math.min(2, imageFiles.length).toInt();
    await Future.wait(
      List<Future<void>>.generate(workerCount, (_) => runWorker()),
    );
    return SmartScanBatchResult(
      results: Map.unmodifiable(results),
      wasCancelled: activeToken.isCancelled,
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
    late final String preprocessedPath;
    try {
      preprocessedPath = await _runOcrPreprocessWorker(
        imageFile: imageFile,
        tempPath: tempDirectory.path,
        jobId: jobId,
        token: activeToken,
      );
    } on _ScanWorkerCancelled {
      rethrow;
    } on TimeoutException {
      return const DocumentClassification(
        type: DocumentType.unknown,
        normalizedText: '',
        confidence: 0,
        reason: 'تجاوزت معالجة OCR المهلة؛ اختر نوع المستند أو راجعه يدوياً.',
        requiresManualReview: true,
      );
    } on StateError {
      return const DocumentClassification(
        type: DocumentType.unknown,
        normalizedText: '',
        confidence: 0,
        reason: 'تعذر تشغيل معالجة OCR؛ اختر نوع المستند أو راجعه يدوياً.',
        requiresManualReview: true,
      );
    }
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
    } catch (error, stackTrace) {
      _logScannerError('classify-document', error, stackTrace);
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
