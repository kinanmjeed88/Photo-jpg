import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../providers/app_state.dart';

class MLKitService {
  /// Feature 1: Auto-Categorization (Smart Routing)
  /// Scans the cropped document for key headers and automatically determines the type.
  Future<DocumentType> autoCategorizeDocument(File imageFile) async {
    final imagePath = imageFile.path;
    final inputImage = InputImage.fromFilePath(imagePath);
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

    try {
      final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
      final text = recognizedText.text;

      if (text.contains('البطاقة الوطنية') || text.contains('جمهورية العراق')) {
        return DocumentType.nationalId;
      } else if (text.contains('مكتب معلومات') || text.contains('اسم رب الاسرة') || text.contains('بطاقة السكن')) {
        return DocumentType.housingCard;
      } else if (text.contains('وزارة التجارة') || text.contains('بطاقة تموين') || text.contains('البطاقة التموينية')) {
        return DocumentType.rationCard;
      } else if (text.contains('Passport') || text.contains('جواز سفر') || text.contains('جواز السفر')) {
        return DocumentType.passport;
      }

      return DocumentType.unknown;
    } catch (e) {
      print('Auto-categorization failed: $e');
      return DocumentType.unknown;
    } finally {
      textRecognizer.close();
    }
  }

  /// Feature 2: Smart Auto-Naming (OCR Extraction)
  /// Extracts the user's primary name from the text blocks to dynamically generate the PDF filename.
  Future<String?> extractPrimaryName(File imageFile) async {
    final imagePath = imageFile.path;
    final inputImage = InputImage.fromFilePath(imagePath);
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

    try {
      final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
      // Stub logic: iterate over blocks and find a probable name line
      // Real logic would involve regex or position-based heuristics for Iraqi docs
      for (TextBlock block in recognizedText.blocks) {
        if (block.text.length > 5 && !block.text.contains(RegExp(r'[0-9]'))) {
          // Assume the first mostly-text block might be the name
          // Just a placeholder implementation
          return 'Documents_${block.text.replaceAll(' ', '_')}.pdf';
        }
      }
      return null;
    } catch (e) {
      print('Name extraction failed: $e');
      return null;
    } finally {
      textRecognizer.close();
    }
  }
}
