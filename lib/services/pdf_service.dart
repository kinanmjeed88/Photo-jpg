import 'dart:io';
import 'dart:isolate';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import '../providers/app_state.dart';

class PdfService {
  Future<File> generatePdf({
    required List<ScannedDocument> scannedDocuments,
    required AppState state,
  }) async {
    final output = await getApplicationDocumentsDirectory();
    final outputPath = '${output.path}/${state.fileName}.pdf';

    final imagePaths = scannedDocuments.map((doc) => doc.file.path).toList();
    final displayMethod = state.displayMethod;
    final addFrame = state.addFrame;

    return await Isolate.run(() async {
      final pdf = pw.Document();

      // Filter documents based on settings if necessary.
      // For now, we'll just include all scanned documents, but organize them based on displayMethod.

      // Sort or filter if required by the state.
      // For simplicity, we process what is provided.

      final List<pw.MemoryImage> pdfImages = imagePaths
          .map((path) => pw.MemoryImage(File(path).readAsBytesSync()))
          .toList();

      if (displayMethod == DisplayMethod.onePage && pdfImages.length >= 2) {
        // Front and back on one page
        pdf.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            build: (pw.Context context) {
              return pw.Container(
                decoration: addFrame ? pw.BoxDecoration(border: pw.Border.all(color: PdfColors.black, width: 2)) : null,
                padding: const pw.EdgeInsets.all(20),
                child: pw.Column(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceEvenly,
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  children: [
                    pw.Expanded(child: pw.Image(pdfImages[0], fit: pw.BoxFit.contain)),
                    pw.SizedBox(height: 20),
                    pw.Expanded(child: pw.Image(pdfImages[1], fit: pw.BoxFit.contain)),
                  ],
                ),
              );
            },
          ),
        );
      } else {
        // One image per page (for twoPages or frontOnly, or if only 1 image provided)
        for (var img in pdfImages) {
          pdf.addPage(
            pw.Page(
              pageFormat: PdfPageFormat.a4,
              build: (pw.Context context) {
                return pw.Container(
                  decoration: addFrame ? pw.BoxDecoration(border: pw.Border.all(color: PdfColors.black, width: 2)) : null,
                  padding: const pw.EdgeInsets.all(20),
                  child: pw.Center(
                    child: pw.Image(img, fit: pw.BoxFit.contain),
                  ),
                );
              },
            ),
          );
        }
      }

      final file = File(outputPath);
      await file.writeAsBytes(await pdf.save());
      return file;
    });
  }
}
