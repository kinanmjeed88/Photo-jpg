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

File? _processPatch(
  cv.Mat srcClone,
  Map<String, dynamic> rectMap,
  String tempPath,
  int count,
) {
  cv.Mat? patch;
  cv.Mat? gray;
  cv.Mat? blurred;
  cv.Mat? edges;
  cv.Mat? kernel;
  cv.Mat? dilated;
  cv.Mat? closed;
  cv.Contours? contours;
  cv.VecVec4i? hierarchy;
  cv.Mat? warped;
  cv.VecPoint? approx;
  cv.VecPoint? orderedPts;
  cv.VecPoint? dstPts;
  cv.Mat? transMat;

  try {
    int rLeft = rectMap['left'] as int;
    int rTop = rectMap['top'] as int;
    int rWidth = rectMap['width'] as int;
    int rHeight = rectMap['height'] as int;

    // Add padding (e.g., 20 pixels) to ensure physical edges are included.
    int pad = 20;
    int left = (rLeft - pad < 0) ? 0 : rLeft - pad;
    int top = (rTop - pad < 0) ? 0 : rTop - pad;
    int right = (rLeft + rWidth + pad > srcClone.cols)
        ? srcClone.cols
        : rLeft + rWidth + pad;
    int bottom = (rTop + rHeight + pad > srcClone.rows)
        ? srcClone.rows
        : rTop + rHeight + pad;

    int width = right - left;
    int height = bottom - top;

    if (width <= 0 || height <= 0) return null;

    cv.Rect patchRect = cv.Rect(left, top, width, height);
    patch = srcClone.region(patchRect);

    gray = cv.cvtColor(patch, cv.COLOR_BGR2GRAY);
    blurred = cv.gaussianBlur(gray, (7, 7), 0);
    edges = cv.canny(blurred, 50, 150);
    kernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
    dilated = cv.dilate(edges, kernel);
    closed = cv.morphologyEx(dilated, cv.MORPH_CLOSE, kernel);

    final (conts, hier) = cv.findContours(
      closed,
      cv.RETR_EXTERNAL,
      cv.CHAIN_APPROX_SIMPLE,
    );
    contours = conts;
    hierarchy = hier;

    double imageArea = (gray.rows * gray.cols).toDouble();

    cv.VecPoint? bestApprox;
    double maxArea = -1;

    for (var contour in contours) {
      final area = cv.contourArea(contour);
      if (area < imageArea * 0.05 || area > imageArea * 0.85) {
        continue;
      }

      final double peri = cv.arcLength(contour, true);
      final cv.VecPoint currentApprox = cv.approxPolyDP(
        contour,
        0.02 * peri,
        true,
      );

      if (currentApprox.length != 4) {
        currentApprox.dispose();
        continue;
      }

      final cv.Rect rect = cv.boundingRect(currentApprox);
      final double ratio = rect.width / rect.height;
      if (ratio < 0.5 || ratio > 2.0) {
        currentApprox.dispose();
        continue;
      }

      if (area > maxArea) {
        maxArea = area;
        if (bestApprox != null) {
          bestApprox.dispose();
        }
        bestApprox = currentApprox;
      } else {
        currentApprox.dispose();
      }
    }

    if (bestApprox == null) {
      return null;
    }

    approx = bestApprox;
    orderedPts = _orderPoints(approx);

    // Calculate width and height of the new warped image
    var p0 = orderedPts[0]; // tl
    var p1 = orderedPts[1]; // tr
    var p2 = orderedPts[2]; // br
    var p3 = orderedPts[3]; // bl

    // It requires dart:math, but we can avoid it with simple approximations
    int widthA = (p2.x - p3.x).abs();
    int widthB = (p1.x - p0.x).abs();
    int maxWidth = widthA > widthB ? widthA : widthB;

    int heightA = (p1.y - p2.y).abs();
    int heightB = (p0.y - p3.y).abs();
    int maxHeight = heightA > heightB ? heightA : heightB;

    dstPts = cv.VecPoint.fromList([
      cv.Point(0, 0),
      cv.Point(maxWidth - 1, 0),
      cv.Point(maxWidth - 1, maxHeight - 1),
      cv.Point(0, maxHeight - 1),
    ]);

    transMat = cv.getPerspectiveTransform(orderedPts, dstPts);

    warped = cv.warpPerspective(patch, transMat, (maxWidth, maxHeight));

    final croppedPath =
        '$tempPath/smart_cropped_${DateTime.now().millisecondsSinceEpoch}_$count.jpg';
    cv.imwrite(croppedPath, warped);
    return File(croppedPath);
  } catch (e) {
    print('OpenCV processing failed for a patch: $e');
    return null;
  } finally {
    patch?.dispose();
    gray?.dispose();
    blurred?.dispose();
    edges?.dispose();
    kernel?.dispose();
    dilated?.dispose();
    closed?.dispose();
    contours?.dispose();
    hierarchy?.dispose();
    warped?.dispose();
    approx?.dispose();
    orderedPts?.dispose();
    dstPts?.dispose();
    transMat?.dispose();
  }
}

Future<List<File>> _isolateProcessSmartCVLayer(
  Map<String, dynamic> args,
) async {
  final String tempPath = args['tempPath'] as String;
  final String imagePath = args['imagePath'] as String;
  final List<dynamic> roisList = args['rois'] as List<dynamic>;
  final bool foundAnchors = args['foundAnchors'] as bool;

  cv.Mat? src;
  cv.Mat? srcClone;

  try {
    final bytes = File(imagePath).readAsBytesSync();
    src = cv.imdecode(bytes, cv.IMREAD_COLOR);

    if (src.isEmpty) {
      return [File(imagePath)];
    }

    srcClone = src.clone();

    List<File> croppedFiles = [];
    int count = 0;

    if (foundAnchors) {
      // Tier 1: ML Kit Semantic Cropping
      for (var roiMap in roisList) {
        final File? cropped = _processPatch(
          srcClone,
          roiMap as Map<String, dynamic>,
          tempPath,
          count,
        );
        if (cropped != null) {
          croppedFiles.add(cropped);
        }
        count++;
      }
    } else {
      // Tier 2: OpenCV Blackout Fallback
      cv.Mat? mask;
      cv.Mat? gray;
      cv.Mat? openedMask;
      cv.Mat? eroded;
      cv.Contours? contours;
      cv.VecVec4i? hierarchy;

      try {
        // 1. Convert to Grayscale
        gray = cv.cvtColor(srcClone, cv.COLOR_BGR2GRAY);

        // 2. Isolate white background and invert
        // White paper should be bright. We threshold high brightness areas.
        final lowerWhite = cv.Mat.fromScalar(1, 1, cv.MatType.CV_8UC1, cv.Scalar(150, 0, 0, 0));
        final upperWhite = cv.Mat.fromScalar(1, 1, cv.MatType.CV_8UC1, cv.Scalar(255, 0, 0, 0));
        mask = cv.inRange(gray, lowerWhite, upperWhite);

        // Invert the mask so the paper background becomes BLACK (0) and the ID cards become WHITE (255)
        final invMaskRaw = cv.bitwiseNOT(mask);

        // 3. Apply MORPH_OPEN (Erosion followed by Dilation) using a 7x7 kernel to destroy shadow bridges.
        final kernel = cv.getStructuringElement(cv.MORPH_RECT, (7, 7));
        eroded = cv.erode(invMaskRaw, kernel);
        openedMask = cv.dilate(eroded, kernel);

        // 4. Contour Detection
        final (conts, hier) = cv.findContours(
          openedMask,
          cv.RETR_EXTERNAL,
          cv.CHAIN_APPROX_SIMPLE,
        );
        contours = conts;
        hierarchy = hier;

        double imageArea = (gray.rows * gray.cols).toDouble();

        for (var contour in contours) {
          final area = cv.contourArea(contour);
          if (area < imageArea * 0.05 || area > imageArea * 0.85) {
            continue;
          }

          final cv.Rect rect = cv.boundingRect(contour);
          final double ratio = rect.width / rect.height;
          // Apply geometric filters (Aspect Ratio 1.35 - 1.75)
          // Considering both landscape and portrait
          if ((ratio >= 1.35 && ratio <= 1.75) || (ratio >= (1.0 / 1.75) && ratio <= (1.0 / 1.35))) {
             // We found a valid document contour, let's crop it.
             // We could use minAreaRect or approxPolyDP for rotated bounding box,
             // but let's stick to simple bounding rect first as per prompt.

             // Optionally, if you want exact perspective crop, you'd do approxPolyDP here
             // but prompt says "crop the original image using these precise coordinates"

             final double peri = cv.arcLength(contour, true);
             final cv.VecPoint currentApprox = cv.approxPolyDP(
                contour,
                0.02 * peri,
                true,
             );

             if (currentApprox.length == 4) {
               final approx = currentApprox;
               final orderedPts = _orderPoints(approx);

               var p0 = orderedPts[0]; // tl
               var p1 = orderedPts[1]; // tr
               var p2 = orderedPts[2]; // br
               var p3 = orderedPts[3]; // bl

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
               final warped = cv.warpPerspective(srcClone, transMat, (maxWidth, maxHeight));

               final croppedPath =
                 '$tempPath/smart_cropped_${DateTime.now().millisecondsSinceEpoch}_$count.jpg';
               cv.imwrite(croppedPath, warped);
               croppedFiles.add(File(croppedPath));

               warped.dispose();
               transMat.dispose();
               dstPts.dispose();
               orderedPts.dispose();
               approx.dispose();
             } else {
               // Fallback to bounding rect if not exactly 4 points after blackout
               final cropped = srcClone.region(rect);
               final croppedPath =
                 '$tempPath/smart_cropped_${DateTime.now().millisecondsSinceEpoch}_$count.jpg';
               cv.imwrite(croppedPath, cropped);
               croppedFiles.add(File(croppedPath));
               cropped.dispose();
             }
             count++;
          }
        }
      } catch (e) {
        print('OpenCV Blackout fallback failed: $e');
      } finally {
        mask?.dispose();
        openedMask?.dispose();
        eroded?.dispose();
        gray?.dispose();
        contours?.dispose();
        hierarchy?.dispose();
      }
    }

    if (croppedFiles.isEmpty) {
      return [File(imagePath)];
    }
    return croppedFiles;
  } catch (e) {
    print('Smart CV Layer failed: $e');
    return [File(imagePath)];
  } finally {
    src?.dispose();
    srcClone?.dispose();
  }
}

class ScannerService {
  final ImagePicker _picker = ImagePicker();

  Future<File?> scanDocument({ImageSource source = ImageSource.camera}) async {
    final XFile? image = await _picker.pickImage(source: source);
    if (image == null) return null;

    final CroppedFile? croppedFile = await ImageCropper().cropImage(
      sourcePath: image.path,
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

    // Stage 1: On-Device AI ROI Detection
    final bytes = await imageFile.readAsBytes();
    final decodedImage = await decodeImageFromList(bytes);
    final double imgWidth = decodedImage.width.toDouble();
    final double imgHeight = decodedImage.height.toDouble();

    final inputImage = InputImage.fromFilePath(imagePath);
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin /* TODO: Fix ML Kit missing arabic */ );

    List<Map<String, dynamic>> rois = [];
    bool foundAnchors = false;

    try {
      final RecognizedText recognizedText = await textRecognizer.processImage(
        inputImage,
      );

      // Search for specific Iraqi Document Anchors
      final text = recognizedText.text;
      if (text.contains('جمهورية العراق') ||
          text.contains('البطاقة الوطنية') ||
          text.contains('جهة الاصدار') ||
          text.contains('<<<') ||
          text.contains('مكتب معلومات') ||
          text.contains('اسم رب الاسرة') ||
          text.contains('Passport') ||
          text.contains('جواز سفر') ||
          text.contains('وزارة التجارة') ||
          text.contains('بطاقة تموين')) {
        foundAnchors = true;
      }

      if (foundAnchors) {
        // Collect bounding boxes of all text blocks
        List<Rect> textBlocks = [];
        for (TextBlock block in recognizedText.blocks) {
          textBlocks.add(block.boundingBox);
        }

        // Cluster the text blocks to form document ROIs
        bool changed = true;
        while (changed) {
          changed = false;
          for (int i = 0; i < textBlocks.length; i++) {
            for (int j = i + 1; j < textBlocks.length; j++) {
              final r1 = textBlocks[i];
              final r2 = textBlocks[j];
              // Inflate by distance threshold to group close blocks (e.g., 100 pixels)
              final expandedR1 = r1.inflate(100);
              if (expandedR1.overlaps(r2)) {
                final unionRect = r1.expandToInclude(r2);
                if (unionRect.width <= imgWidth * 0.5 && unionRect.height <= imgHeight * 0.5) {
                  textBlocks[i] = unionRect;
                  textBlocks.removeAt(j);
                  changed = true;
                  break;
                }
              }
            }
            if (changed) break;
          }
        }

        for (Rect r in textBlocks) {
          // Add standard padding (~30 pixels) to the Union Rect
          int pad = 30;
          rois.add({
            'left': (r.left - pad).toInt(),
            'top': (r.top - pad).toInt(),
            'width': (r.width + pad * 2).toInt(),
            'height': (r.height + pad * 2).toInt(),
          });
        }
      }
    } catch (e) {
      print('ML Kit Text Recognition failed: $e');
    } finally {
      textRecognizer.close();
    }

    final args = {
      'tempPath': tempPath,
      'imagePath': imagePath,
      'rois': rois,
      'foundAnchors': foundAnchors,
    };

    // Stage 2: OpenCV Precision Cropping (in background isolate)
    return await Isolate.run(() => _isolateProcessSmartCVLayer(args));
  }

  Future<DocumentType> classifyDocument(File imageFile) async {
    final imagePath = imageFile.path;
    final inputImage = InputImage.fromFilePath(imagePath);
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin /* TODO: Fix ML Kit missing arabic */ );

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
