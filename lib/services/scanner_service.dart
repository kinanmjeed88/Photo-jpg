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
            lockAspectRatio: false),
        IOSUiSettings(
          title: 'تعديل الصورة',
        ),
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
      decodedImage = img.adjustColor(decodedImage, contrast: 1.5, exposure: 0.1);
    }

    final newBytes = img.encodeJpg(decodedImage, quality: 90);
    final filteredFile = File(imageFile.path)..writeAsBytesSync(newBytes);

    return filteredFile;
  }

  Future<List<File>> processSmartRecognition(File imageFile) async {
    final tempDir = await getTemporaryDirectory();
    final tempPath = tempDir.path;
    final imagePath = imageFile.path;

    return await Isolate.run(() async {
      cv.Mat? src;
      cv.Mat? srcClone;
      cv.Mat? gray;
      cv.Mat? blurred;
      cv.Mat? edges;

      try {
        final bytes = File(imagePath).readAsBytesSync();
        src = cv.imdecode(bytes, cv.IMREAD_COLOR);
        srcClone = src.clone();

        gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
        blurred = cv.gaussianBlur(gray, (5, 5), 0);

        final (_, edgesOut) = cv.threshold(blurred, 0, 255, cv.THRESH_BINARY + cv.THRESH_OTSU);
        edges = edgesOut;

        final (contours, _) = cv.findContours(edges, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

        List<File> croppedFiles = [];
        double minArea = 10000;
        int count = 0;

        for (var contour in contours) {
          final area = cv.contourArea(contour);
          if (area > minArea) {
            final rect = cv.boundingRect(contour);
            final croppedMat = srcClone.region(rect);
            final croppedPath = '$tempPath/smart_cropped_${DateTime.now().millisecondsSinceEpoch}_$count.jpg';
            cv.imwrite(croppedPath, croppedMat);
            croppedFiles.add(File(croppedPath));
            croppedMat.dispose();
            count++;
          }
        }

        if (croppedFiles.isEmpty) {
          return [File(imagePath)];
        }
        return croppedFiles;
      } catch (e) {
        print('Smart recognition failed: $e');
        return [File(imagePath)];
      } finally {
        src?.dispose();
        srcClone?.dispose();
        gray?.dispose();
        blurred?.dispose();
        edges?.dispose();
      }
    });
  }

  Future<DocumentType> classifyDocument(File imageFile) async {
    final imagePath = imageFile.path;
    final rootToken = RootIsolateToken.instance!;

    return await Isolate.run(() async {
      BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
      final inputImage = InputImage.fromFilePath(imagePath);
      final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

      try {
        final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
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
    });
  }

  Future<File> processAutoDeskew(File imageFile) async {
    final tempDir = await getTemporaryDirectory();
    final tempPath = tempDir.path;
    final imagePath = imageFile.path;

    return await Isolate.run(() async {
      cv.Mat? src;
      cv.Mat? srcClone;
      cv.Mat? gray;
      cv.Mat? blurred;
      cv.Mat? edges;
      cv.Mat? m;
      cv.Mat? warped;

      try {
        final bytes = File(imagePath).readAsBytesSync();
        src = cv.imdecode(bytes, cv.IMREAD_COLOR);
        srcClone = src.clone();

        gray = cv.cvtColor(src, cv.COLOR_BGR2GRAY);
        blurred = cv.gaussianBlur(gray, (5, 5), 0);
        edges = cv.canny(blurred, 75.0, 200.0);

        final (contours, _) = cv.findContours(edges, cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE);
        final sortedContours = contours.toList()..sort((a, b) => cv.contourArea(b).compareTo(cv.contourArea(a)));

        cv.VecPoint? docContour;

        for (var contour in sortedContours) {
          final peri = cv.arcLength(contour, true);
          final approx = cv.approxPolyDP(contour, 0.02 * peri, true);

          if (approx.length == 4) {
            docContour = approx;
            break;
          }
        }

        if (docContour != null) {
          final points = docContour.toList();

          points.sort((a, b) => (a.x + a.y).compareTo(b.x + b.y));
          final tl = points[0];
          final br = points[3];

          final remaining = [points[1], points[2]];
          remaining.sort((a, b) => (a.x - a.y).compareTo(b.x - b.y));
          final tr = remaining[1];
          final bl = remaining[0];

          final widthA = (tr.x - tl.x).abs().toDouble();
          final widthB = (br.x - bl.x).abs().toDouble();
          final maxWidth = widthA > widthB ? widthA : widthB;

          final heightA = (bl.y - tl.y).abs().toDouble();
          final heightB = (br.y - tr.y).abs().toDouble();
          final maxHeight = heightA > heightB ? heightA : heightB;

          final dstPoints = [
            cv.Point(0, 0),
            cv.Point(maxWidth.toInt() - 1, 0),
            cv.Point(maxWidth.toInt() - 1, maxHeight.toInt() - 1),
            cv.Point(0, maxHeight.toInt() - 1),
          ];

          final srcPoints = [tl, tr, br, bl];

          m = cv.getPerspectiveTransform(cv.VecPoint.fromList(srcPoints), cv.VecPoint.fromList(dstPoints));
          warped = cv.warpPerspective(srcClone, m, (maxWidth.toInt(), maxHeight.toInt()));

          final deskewedPath = '$tempPath/deskewed_${DateTime.now().millisecondsSinceEpoch}.jpg';
          cv.imwrite(deskewedPath, warped);

          return File(deskewedPath);
        }

        return File(imagePath);
      } catch (e) {
        print('Auto deskew failed: $e');
        return File(imagePath);
      } finally {
        src?.dispose();
        srcClone?.dispose();
        gray?.dispose();
        blurred?.dispose();
        edges?.dispose();
        m?.dispose();
        warped?.dispose();
      }
    });
  }
}
