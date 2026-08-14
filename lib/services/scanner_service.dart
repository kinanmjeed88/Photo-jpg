import 'dart:io';
import 'dart:async';
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

Future<List<String>> _detectAndCropInIsolate(
  Map<String, dynamic> args, {
  bool Function()? isCancelled,
}) async {
  final imagePath = args['imagePath'] as String;
  final tempPath = args['tempPath'] as String;
  final jobId = args['jobId'] as String? ?? 'legacy';
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

    // Keep the vision workload bounded. A preview-sized working image is
    // sufficient for document boundaries and prevents one large camera image
    // from monopolising the smart-scan isolate.
    const maximumAnalysisDimension = 1600;
    final largestDimension = source.cols > source.rows
        ? source.cols
        : source.rows;
    if (largestDimension > maximumAnalysisDimension) {
      final scale = maximumAnalysisDimension / largestDimension;
      final resized = cv.resize(source, (0, 0), fx: scale, fy: scale);
      source.dispose();
      source = resized;
    }

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

    var inspectedContours = 0;
    for (final contour in contours) {
      if (isCancelled?.call() ?? false) return results;
      // Yield between contours so the control port can deliver cancellation.
      await Future<void>.delayed(Duration.zero);
      if (isCancelled?.call() ?? false) return results;
      // The largest useful document outlines occur early in this contour list.
      // A hard upper bound preserves interactive response for noisy photos.
      if (inspectedContours++ >= 120 || results.length >= 4) break;
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
            '$tempPath/${TemporaryImageStore.uniqueJpegName('smart_cropped_', suffix: '-$jobId-${results.length}')}';
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
    final jobId = DateTime.now().microsecondsSinceEpoch.toString();
    List<String> outputPaths;
    try {
      outputPaths = await _runSmartCropWorker(
        imageFile: imageFile,
        tempPath: tempDirectory.path,
        jobId: jobId,
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
      classification =
          await classifyDocument(
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
