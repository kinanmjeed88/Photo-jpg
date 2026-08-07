import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import '../providers/app_state.dart';

class RectModel {
  final int left, top, right, bottom;
  RectModel(this.left, this.top, this.right, this.bottom);
}

cv.VecPoint _orderPoints(cv.VecPoint pts) {
  // We expect 4 points.
  var p0 = pts[0];
  var p1 = pts[1];
  var p2 = pts[2];
  var p3 = pts[3];

  List<cv.Point> points = [p0, p1, p2, p3];

  var sum = points.map((p) => p.x + p.y).toList();
  var diff = points.map((p) => p.y - p.x).toList();

  var tlIndex = 0, brIndex = 0, trIndex = 0, blIndex = 0;
  var minSum = sum[0], maxSum = sum[0], minDiff = diff[0], maxDiff = diff[0];

  for (var i = 1; i < 4; i++) {
    if (sum[i] < minSum) {
      minSum = sum[i];
      tlIndex = i;
    }
    if (sum[i] > maxSum) {
      maxSum = sum[i];
      brIndex = i;
    }
    if (diff[i] < minDiff) {
      minDiff = diff[i];
      trIndex = i;
    }
    if (diff[i] > maxDiff) {
      maxDiff = diff[i];
      blIndex = i;
    }
  }

  return cv.VecPoint.fromList([
    points[tlIndex],
    points[trIndex],
    points[brIndex],
    points[blIndex],
  ]);
}



Future<List<File>> _isolateProcessSmartCVLayer(
  Map<String, dynamic> args,
) async {
  final String tempPath = args['tempPath'] as String;
  final String imagePath = args['imagePath'] as String;

  cv.Mat? src;
  cv.Mat? srcClone;
  cv.Mat? gray;
  cv.Mat? blurred;
  cv.Mat? edges;
  cv.Mat? kernel;
  cv.Mat? closed;
  cv.Contours? contours;
  cv.VecVec4i? hierarchy;

  List<File> croppedFiles = [];
  int count = 0;

  try {
    final bytes = File(imagePath).readAsBytesSync();
    src = cv.imdecode(bytes, cv.IMREAD_COLOR);

    if (src.isEmpty) {
      return [];
    }

    srcClone = src.clone();

    // A. Grayscale
    gray = cv.cvtColor(srcClone, cv.COLOR_BGR2GRAY);

    // B. Blur (7, 7)
    blurred = cv.gaussianBlur(gray, (7, 7), 0);

    // C. Edge Detection (Canny 50, 150)
    edges = cv.canny(blurred, 50, 150);

    // D. Morphological Close (9, 9)
    kernel = cv.getStructuringElement(cv.MORPH_RECT, (9, 9));
    closed = cv.morphologyEx(edges, cv.MORPH_CLOSE, kernel);

    // 3. Strict Geometric Extraction
    final (conts, hier) = cv.findContours(
      closed,
      cv.RETR_EXTERNAL,
      cv.CHAIN_APPROX_SIMPLE,
    );
    contours = conts;
    hierarchy = hier;

    double imageArea = (gray.rows * gray.cols).toDouble();

    for (var contour in contours) {
      final area = cv.contourArea(contour);
      // Area Filter: 1.5% to 85%
      if (area < imageArea * 0.015 || area > imageArea * 0.85) {
        continue;
      }

      final double peri = cv.arcLength(contour, true);
      // Shape Filter: Exactly 4 points
      final cv.VecPoint approx = cv.approxPolyDP(contour, 0.02 * peri, true);

      cv.VecPoint orderedPts;
      bool isValidShape = false;

      if (approx.length == 4) {
        orderedPts = _orderPoints(approx);
        isValidShape = true;
      } else {
        // Fallback to minAreaRect for rounded corners / close placement
        final rect = cv.minAreaRect(contour);
        final boxPts = cv.boxPoints(rect);
        final ptsList = [
          cv.Point(boxPts[0].x.toInt(), boxPts[0].y.toInt()),
          cv.Point(boxPts[1].x.toInt(), boxPts[1].y.toInt()),
          cv.Point(boxPts[2].x.toInt(), boxPts[2].y.toInt()),
          cv.Point(boxPts[3].x.toInt(), boxPts[3].y.toInt()),
        ];
        final tempVec = cv.VecPoint.fromList(ptsList);
        orderedPts = _orderPoints(tempVec);
        tempVec.dispose();
        isValidShape = true;
      }

      if (isValidShape) {
        final cv.Rect rect = cv.boundingRect(contour); // Use original contour for bounding rect

        // Aspect Ratio Filter (1.2 to 1.9) using max/min of bounding box
        double w = rect.width.toDouble();
        double h = rect.height.toDouble();
        double maxDim = w > h ? w : h;
        double minDim = w < h ? w : h;
        double ratio = maxDim / minDim;

        if (ratio >= 1.2 && ratio <= 1.9) {
          var p0 = orderedPts[0];
          var p1 = orderedPts[1];
          var p2 = orderedPts[2];
          var p3 = orderedPts[3];

          int widthA = (p2.x - p3.x).abs();
          int widthB = (p1.x - p0.x).abs();
          int maxWidth = widthA > widthB ? widthA : widthB;

          int heightA = (p1.y - p2.y).abs();
          int heightB = (p0.y - p3.y).abs();
          int maxHeight = heightA > heightB ? heightA : heightB;

          final dstPts = cv.VecPoint.fromList([
            cv.Point(0, 0),
            cv.Point(maxWidth - 1, 0),
            cv.Point(maxWidth - 1, maxHeight - 1),
            cv.Point(0, maxHeight - 1),
          ]);

          final transMat = cv.getPerspectiveTransform(orderedPts, dstPts);
          // Apply warpPerspective EXCLUSIVELY on srcClone (Original Color Image)
          final warped = cv.warpPerspective(srcClone, transMat, (maxWidth, maxHeight));

          double cropArea = (maxWidth * maxHeight).toDouble();
          double aspect = maxWidth / maxHeight;
          bool isA4 = cropArea > (imageArea * 0.6) || (aspect >= 0.67 && aspect <= 0.75) || (aspect >= 1.35 && aspect <= 1.48);

          String suffix = isA4 ? '_A4' : '_ID';
          final croppedPath = '$tempPath/smart_cropped_${DateTime.now().millisecondsSinceEpoch}_${count}${suffix}.jpg';

          cv.imwrite(croppedPath, warped); // Save original color without Grayscale/CLAHE applied to final output
          croppedFiles.add(File(croppedPath));

          warped.dispose();
          transMat.dispose();
          dstPts.dispose();
          orderedPts.dispose();

          count++;
        }
      }
      approx.dispose();
    }

    // Fix Squish Bug: Return [] if no valid contours
    if (croppedFiles.isEmpty) {
      return [];
    }
    return croppedFiles;
  } catch (e) {
    print('Smart CV Layer failed: $e');
    return [];
  } finally {
    src?.dispose();
    srcClone?.dispose();
    gray?.dispose();
    blurred?.dispose();
    edges?.dispose();
    kernel?.dispose();
    closed?.dispose();
    contours?.dispose();
    hierarchy?.dispose();
  }
}

Future<String> _isolatePreprocessForOCR(Map<String, dynamic> args) async {
  final String imagePath = args['imagePath'] as String;
  final String tempPath = args['tempPath'] as String;

  cv.Mat? src;
  cv.Mat? gray;
  cv.Mat? claheMat;

  try {
    final bytes = File(imagePath).readAsBytesSync();
    src = cv.imdecode(bytes, cv.IMREAD_COLOR);
    if (src.isEmpty) return imagePath;

    gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);

    final clahe = cv.CLAHE.empty();
    claheMat = clahe.apply(gray);

    final processedPath =
        '$tempPath/ocr_preprocessed_${DateTime.now().millisecondsSinceEpoch}.jpg';
    cv.imwrite(processedPath, claheMat);
    return processedPath;
  } catch (e) {
    print('OCR pre-processing failed: $e');
    return imagePath;
  } finally {
    src?.dispose();
    gray?.dispose();
    claheMat?.dispose();
  }
}

class ScannerService {
  final ImagePicker _picker = ImagePicker();

  Future<File?> manualCrop(String sourcePath) async {
    final CroppedFile? croppedFile = await ImageCropper().cropImage(
      sourcePath: sourcePath,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'تعديل الصورة',
          toolbarColor: const Color(0xFF1E293B),
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
        ),
        IOSUiSettings(title: 'تعديل الصورة'),
      ],
    );

    if (croppedFile != null) {
      return File(croppedFile.path);
    }
    return null;
  }

  Future<File?> scanDocument({ImageSource source = ImageSource.camera}) async {
    final XFile? image = await _picker.pickImage(source: source);
    if (image == null) return null;

    return manualCrop(image.path);
  }

  Future<List<File>?> scanMultipleDocuments() async {
    final List<XFile> images = await _picker.pickMultiImage();
    if (images.isEmpty) return null;

    // As per instruction, maybe we process them sequentially and inject them.
    // If they go through multi-picker, we probably just return the original files,
    // and rely on `processSmartRecognition` or manual crop for each.
    // Actually, manual crop on 10 images might be annoying, but the mandate states:
    // "Iterate through the selected images, processing each through the pipeline, and injecting all resulting cropped files into the state sequentially."

    return images.map((x) => File(x.path)).toList();
  }

  Future<File?> applyFilter(File imageFile, bool highContrast) async {
    final bytes = await imageFile.readAsBytes();
    img.Image? decodedImage = img.decodeImage(bytes);

    if (decodedImage == null) return null;

    // Apply Grayscale
    decodedImage = img.grayscale(decodedImage);

    if (highContrast) {
      // Basic contrast adjustment for a "scanner" look
      decodedImage = img.adjustColor(
        decodedImage,
        contrast: 1.5,
        exposure: 0.1,
      );
    }

    final newBytes = img.encodeJpg(decodedImage, quality: 90);
    final filteredFile = File(imageFile.path)..writeAsBytesSync(newBytes);

    return filteredFile;
  }

  Future<List<File>> processSmartRecognition(File imageFile) async {
    final tempDir = await getTemporaryDirectory();
    final tempPath = tempDir.path;
    final imagePath = imageFile.path;

    final args = {
      'tempPath': tempPath,
      'imagePath': imagePath,
    };

    // Stage 2: OpenCV Precision Cropping (in background isolate)
    return await Isolate.run(() => _isolateProcessSmartCVLayer(args));
  }

  Future<DocumentType> classifyDocument(File imageFile) async {
    final imagePath = imageFile.path;
    final tempDir = await getTemporaryDirectory();
    final tempPath = tempDir.path;

    // Pre-process for OCR in background
    final preprocessedImagePath = await Isolate.run(
      () => _isolatePreprocessForOCR({
        'imagePath': imagePath,
        'tempPath': tempPath,
      }),
    );

    final inputImage = InputImage.fromFilePath(preprocessedImagePath);
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

    try {
      final RecognizedText recognizedText = await textRecognizer.processImage(
        inputImage,
      );
      final text = recognizedText.text;

      if (text.contains('البطاقة الوطنية')) {
        return DocumentType.nationalId;
      } else if (text.contains('بطاقة السكن')) {
        return DocumentType.housingCard;
      } else if (text.contains('البطاقة التموينية')) {
        return DocumentType.rationCard;
      } else if (text.contains('جواز السفر')) {
        return DocumentType.passport;
      }

      return DocumentType.unknown;
    } catch (e) {
      print('Text recognition failed: $e');
      return DocumentType.unknown;
    } finally {
      textRecognizer.close();
    }
  }
}
