import 'dart:io';
import 'dart:isolate';
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

  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
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

cv.VecPoint _orderPoints(cv.VecPoint points) {
  final source = List<cv.Point>.generate(4, (index) => points[index]);
  final sums = source.map((point) => point.x + point.y).toList();
  final diffs = source.map((point) => point.y - point.x).toList();

  int indexOfMin(List<int> values) =>
      values.indexOf(values.reduce((a, b) => a < b ? a : b));
  int indexOfMax(List<int> values) =>
      values.indexOf(values.reduce((a, b) => a > b ? a : b));

  final topLeft = indexOfMin(sums);
  final bottomRight = indexOfMax(sums);
  final topRight = indexOfMin(diffs);
  final bottomLeft = indexOfMax(diffs);

  return cv.VecPoint.fromList(<cv.Point>[
    source[topLeft],
    source[topRight],
    source[bottomRight],
    source[bottomLeft],
  ]);
}

int _clampInt(int value, int lower, int upper) =>
    value.clamp(lower, upper).toInt();

List<String> _detectAndCropInIsolate(Map<String, String> args) {
  final imagePath = args['imagePath']!;
  final tempPath = args['tempPath']!;
  cv.Mat? source;
  cv.Mat? gray;
  cv.Mat? blurred;
  cv.Mat? edges;
  cv.Mat? kernel;
  cv.Mat? closed;
  cv.Contours? contours;
  cv.VecVec4i? hierarchy;
  final results = <String>[];
  final acceptedCenters = <(int, int)>[];

  try {
    source = cv.imdecode(File(imagePath).readAsBytesSync(), cv.IMREAD_COLOR);
    if (source.isEmpty) return results;

    gray = cv.cvtColor(source, cv.COLOR_BGR2GRAY);
    blurred = cv.gaussianBlur(gray, (5, 5), 0);
    edges = cv.canny(blurred, 40, 120);
    kernel = cv.getStructuringElement(cv.MORPH_RECT, (9, 9));
    closed = cv.morphologyEx(edges, cv.MORPH_CLOSE, kernel);
    final contourResult = cv.findContours(
      closed,
      cv.RETR_LIST,
      cv.CHAIN_APPROX_SIMPLE,
    );
    contours = contourResult.$1;
    hierarchy = contourResult.$2;
    final imageArea = (source.rows * source.cols).toDouble();

    for (final contour in contours) {
      cv.VecPoint? approximation;
      cv.VecPoint? ordered;
      cv.VecPoint? sourcePoints;
      cv.VecPoint? destinationPoints;
      cv.Mat? transform;
      cv.Mat? warped;
      try {
        final area = cv.contourArea(contour);
        if (area < imageArea * 0.035 || area > imageArea * 0.92) continue;

        final perimeter = cv.arcLength(contour, true);
        approximation = cv.approxPolyDP(contour, 0.02 * perimeter, true);
        if (approximation.length == 4) {
          ordered = _orderPoints(approximation);
        } else {
          final rectangle = cv.minAreaRect(contour);
          final box = cv.boxPoints(rectangle);
          final boxPoints = cv.VecPoint.fromList(<cv.Point>[
            cv.Point(box[0].x.round(), box[0].y.round()),
            cv.Point(box[1].x.round(), box[1].y.round()),
            cv.Point(box[2].x.round(), box[2].y.round()),
            cv.Point(box[3].x.round(), box[3].y.round()),
          ]);
          ordered = _orderPoints(boxPoints);
          boxPoints.dispose();
        }

        final points = List<cv.Point>.generate(4, (index) => ordered![index]);
        final centerX = (points.fold<int>(0, (sum, point) => sum + point.x) / 4)
            .round();
        final centerY = (points.fold<int>(0, (sum, point) => sum + point.y) / 4)
            .round();
        final duplicate = acceptedCenters.any((center) {
          final deltaX = center.$1 - centerX;
          final deltaY = center.$2 - centerY;
          return deltaX * deltaX + deltaY * deltaY < 2500;
        });
        if (duplicate) continue;

        final widthTop = (points[1].x - points[0].x).abs();
        final widthBottom = (points[2].x - points[3].x).abs();
        final heightRight = (points[2].y - points[1].y).abs();
        final heightLeft = (points[3].y - points[0].y).abs();
        final width = widthTop > widthBottom ? widthTop : widthBottom;
        final height = heightRight > heightLeft ? heightRight : heightLeft;
        if (width < 32 || height < 32) continue;

        final ratio = width > height ? width / height : height / width;
        if (ratio > 3.5) continue;

        const padding = 10;
        final padded = <cv.Point>[
          cv.Point(
            _clampInt(points[0].x - padding, 0, source.cols - 1),
            _clampInt(points[0].y - padding, 0, source.rows - 1),
          ),
          cv.Point(
            _clampInt(points[1].x + padding, 0, source.cols - 1),
            _clampInt(points[1].y - padding, 0, source.rows - 1),
          ),
          cv.Point(
            _clampInt(points[2].x + padding, 0, source.cols - 1),
            _clampInt(points[2].y + padding, 0, source.rows - 1),
          ),
          cv.Point(
            _clampInt(points[3].x - padding, 0, source.cols - 1),
            _clampInt(points[3].y + padding, 0, source.rows - 1),
          ),
        ];
        final outputWidth = width + padding * 2;
        final outputHeight = height + padding * 2;
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
            '$tempPath/${TemporaryImageStore.uniqueJpegName('smart_cropped_', suffix: '-${results.length}')}';
        if (cv.imwrite(outputPath, warped)) {
          results.add(outputPath);
          acceptedCenters.add((centerX, centerY));
        }
      } finally {
        approximation?.dispose();
        ordered?.dispose();
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
    kernel?.dispose();
    closed?.dispose();
    contours?.dispose();
    hierarchy?.dispose();
  }
  return results;
}

String _preprocessForOcrInIsolate(Map<String, String> args) {
  final imagePath = args['imagePath']!;
  final tempPath = args['tempPath']!;
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
        '$tempPath/${TemporaryImageStore.uniqueJpegName('ocr_preprocessed_')}';
    return cv.imwrite(outputPath, processed) ? outputPath : imagePath;
  } catch (_) {
    return imagePath;
  } finally {
    source?.dispose();
    gray?.dispose();
    processed?.dispose();
  }
}

class ScannerService {
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

  Future<SmartScanResult> processSmartRecognition(
    File imageFile, {
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

    await TemporaryImageStore.cleanupStale();
    final tempDirectory = await getTemporaryDirectory();
    final outputPaths = await Isolate.run(
      () => _detectAndCropInIsolate(<String, String>{
        'imagePath': imageFile.path,
        'tempPath': tempDirectory.path,
      }),
    );

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
    final classification = await classifyDocument(files.first);
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
    void Function(int current, int total)? onProgress,
    ScanCancellationToken? cancellationToken,
  }) async {
    final results = <File, SmartScanResult>{};
    for (var index = 0; index < imageFiles.length; index++) {
      if (cancellationToken?.isCancelled ?? false) {
        return SmartScanBatchResult(
          results: Map.unmodifiable(results),
          wasCancelled: true,
        );
      }
      final source = imageFiles[index];
      try {
        results[source] = await processSmartRecognition(
          source,
          cancellationToken: cancellationToken,
        );
      } catch (_) {
        results[source] = SmartScanResult(
          source: source,
          files: const <File>[],
          classification: DocumentClassification.unknown,
          status: SmartScanStatus.failed,
          message: 'تعذرت معالجة هذه الصورة؛ يُرجى قصها يدوياً.',
        );
      }
      onProgress?.call(index + 1, imageFiles.length);
    }
    return SmartScanBatchResult(
      results: Map.unmodifiable(results),
      wasCancelled: false,
    );
  }

  Future<DocumentClassification> classifyDocument(File imageFile) async {
    final tempDirectory = await getTemporaryDirectory();
    final preprocessedPath = await Isolate.run(
      () => _preprocessForOcrInIsolate(<String, String>{
        'imagePath': imageFile.path,
        'tempPath': tempDirectory.path,
      }),
    );
    final preprocessedFile = File(preprocessedPath);
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final recognized = await recognizer.processImage(
        InputImage.fromFilePath(preprocessedPath),
      );
      return _classifyRecognizedText(recognized.text);
    } catch (_) {
      return const DocumentClassification(
        type: DocumentType.unknown,
        normalizedText: '',
        confidence: 0,
        reason: 'تعذر استخراج النص تلقائياً؛ اختر نوع المستند يدوياً.',
        requiresManualReview: true,
      );
    } finally {
      await recognizer.close();
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
