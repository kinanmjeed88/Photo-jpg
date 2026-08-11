import 'dart:convert';

class DocumentScannerConfig {
  final String configVersion;
  final double iouMergeThreshold;
  final double minSolidity;
  final List<double> aspectRatioRange;
  final double minAreaRatio;
  final double maxAreaRatio;
  final Map<String, double> weights;

  const DocumentScannerConfig({
    this.configVersion = "1.0",
    this.iouMergeThreshold = 0.6,
    this.minSolidity = 0.85,
    this.aspectRatioRange = const [1.2, 1.9],
    this.minAreaRatio = 0.005,
    this.maxAreaRatio = 0.85,
    this.weights = const {
      'area': 0.2,
      'solidity': 0.25,
      'aspectRatio': 0.15,
      'sharpness': 0.2,
      'rectangularity': 0.2,
    },
  });

  factory DocumentScannerConfig.fromJson(Map<String, dynamic> json) {
    return DocumentScannerConfig(
      configVersion: json['configVersion'] as String? ?? "1.0",
      iouMergeThreshold: (json['iouMergeThreshold'] as num?)?.toDouble() ?? 0.6,
      minSolidity: (json['minSolidity'] as num?)?.toDouble() ?? 0.85,
      aspectRatioRange:
          (json['aspectRatioRange'] as List<dynamic>?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          [1.2, 1.9],
      minAreaRatio: (json['minAreaRatio'] as num?)?.toDouble() ?? 0.005,
      maxAreaRatio: (json['maxAreaRatio'] as num?)?.toDouble() ?? 0.85,
      weights:
          (json['weights'] as Map<String, dynamic>?)?.map(
            (k, e) => MapEntry(k, (e as num).toDouble()),
          ) ??
          {
            'area': 0.2,
            'solidity': 0.25,
            'aspectRatio': 0.15,
            'sharpness': 0.2,
            'rectangularity': 0.2,
          },
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'configVersion': configVersion,
      'iouMergeThreshold': iouMergeThreshold,
      'minSolidity': minSolidity,
      'aspectRatioRange': aspectRatioRange,
      'minAreaRatio': minAreaRatio,
      'maxAreaRatio': maxAreaRatio,
      'weights': weights,
    };
  }

  String toJsonString() => json.encode(toJson());

  factory DocumentScannerConfig.fromJsonString(String source) =>
      DocumentScannerConfig.fromJson(
        json.decode(source) as Map<String, dynamic>,
      );
}
