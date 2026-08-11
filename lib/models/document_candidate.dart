import 'package:opencv_dart/opencv_dart.dart' as cv;

enum SourcePass { adaptive, otsu, canny }

class GeometryMetrics {
  double area;
  double solidity;
  double aspectRatio;
  double rectangularity;

  GeometryMetrics({
    this.area = 0.0,
    this.solidity = 0.0,
    this.aspectRatio = 0.0,
    this.rectangularity = 0.0,
  });
}

class QualityMetrics {
  double sharpness;
  double contrast;

  QualityMetrics({this.sharpness = 0.0, this.contrast = 0.0});
}

class ConsensusMetrics {
  int overlapCount;
  double iouScore;
  double consensusScore;

  ConsensusMetrics({
    this.overlapCount = 1,
    this.iouScore = 1.0,
    this.consensusScore = 0.0,
  });
}

class Metrics {
  GeometryMetrics geometry;
  QualityMetrics quality;
  ConsensusMetrics consensus;

  Metrics({
    GeometryMetrics? geometry,
    QualityMetrics? quality,
    ConsensusMetrics? consensus,
  }) : geometry = geometry ?? GeometryMetrics(),
       quality = quality ?? QualityMetrics(),
       consensus = consensus ?? ConsensusMetrics();
}

class Candidate {
  final SourcePass sourcePass;
  double confidence;
  cv.RotatedRect rotatedRect;
  cv.VecPoint contour;
  Metrics metrics;

  Candidate({
    required this.sourcePass,
    this.confidence = 0.0,
    required this.rotatedRect,
    required this.contour,
    Metrics? metrics,
  }) : metrics = metrics ?? Metrics();
}
