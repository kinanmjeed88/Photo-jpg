import 'dart:io';

import 'package:doc_scanner_app/screens/single_crop_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  testWidgets(
    'SingleCropScreen shows the Arabic crop controls and keeps the editor',
    (WidgetTester tester) async {
      // A real (small) JPEG keeps the editor's image provider loadable, so the
      // screen under test is the same one a user sees.
      final directory = await Directory.systemTemp.createTemp('single_crop_');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/source.jpg');
      await file.writeAsBytes(img.encodeJpg(img.Image(width: 40, height: 24)));

      await tester.pumpWidget(
        MaterialApp(home: SingleCropScreen(imageFile: file)),
      );
      await tester.pump();

      expect(find.text('تعديل الصورة'), findsOneWidget);
      // Aspect-ratio chips are localised; the previous English labels ('Square',
      // '3 × 2', …) no longer exist anywhere in the UI.
      expect(find.text('الأصلي'), findsOneWidget);
      expect(find.text('مربع'), findsOneWidget);
      expect(find.text('3 : 2'), findsOneWidget);
      expect(find.text('4 : 3'), findsOneWidget);
      expect(find.text('16 : 9'), findsOneWidget);
      expect(find.text('حر'), findsOneWidget);
      // The confirm action must be available without an extra dialog.
      expect(find.byTooltip('تأكيد القص'), findsOneWidget);
    },
  );
}
