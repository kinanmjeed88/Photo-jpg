import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image/image.dart' as img;

class ScannerService {
  final ImagePicker _picker = ImagePicker();

  Future<File?> scanDocument() async {
    final XFile? image = await _picker.pickImage(source: ImageSource.camera);
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
}
