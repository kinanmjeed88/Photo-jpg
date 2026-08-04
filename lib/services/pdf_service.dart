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

    // Map document data to primitives to pass to the isolate securely
    final docData = scannedDocuments.map((doc) => {
      'path': doc.file.path,
      'dx': doc.dx,
      'dy': doc.dy,
      'width': doc.width,
      'height': doc.height,
      'pageIndex': doc.pageIndex,
    }).toList();

    return await Isolate.run(() async {
      final pdf = pw.Document();

      // Organize documents by pageIndex
      Map<int, List<Map<String, dynamic>>> pagesData = {};
      for (var data in docData) {
        final int pageIndex = data['pageIndex'] as int;
        if (!pagesData.containsKey(pageIndex)) {
          pagesData[pageIndex] = [];
        }
        pagesData[pageIndex]!.add(data);
      }

      final sortedPageIndices = pagesData.keys.toList()..sort();

      // UI coordinates vs PDF coordinates mapping
      // UI assumes aspect ratio 1 / 1.414, we need to map to PdfPageFormat.a4
      final pdfA4Width = PdfPageFormat.a4.width;
      final pdfA4Height = PdfPageFormat.a4.height;

      // Calculate scaling based on UI reference dimensions
      // (assuming standard screen width mapping, e.g., max canvas width in UI was roughly 350-400 based on device)
      // To ensure accurate PDF generation, we determine relative positioning.
      // In UI, canvasWidth = constraints.maxWidth, canvasHeight = canvasWidth * 1.414
      // We will normalize the coordinates. Let's assume UI was width 400.
      final uiReferenceWidth = 400.0;
      final uiReferenceHeight = uiReferenceWidth * 1.414;

      final scaleX = pdfA4Width / uiReferenceWidth;
      final scaleY = pdfA4Height / uiReferenceHeight;

      for (var pageIndex in sortedPageIndices) {
        final docsOnPage = pagesData[pageIndex]!;

        pdf.addPage(
          pw.Page(
            pageFormat: PdfPageFormat.a4,
            build: (pw.Context context) {
              return pw.Stack(
                children: docsOnPage.map((docData) {
                  final String path = docData['path'] as String;
                  final double dx = docData['dx'] as double;
                  final double dy = docData['dy'] as double;
                  final double docWidth = docData['width'] as double;
                  final double docHeight = docData['height'] as double;

                  final memoryImage = pw.MemoryImage(File(path).readAsBytesSync());

                  // PDF origin is bottom-left, UI origin is top-left
                  final pdfX = dx * scaleX;
                  final pdfY = pdfA4Height - ((dy + docHeight) * scaleY);
                  final pdfWidth = docWidth * scaleX;
                  final pdfHeight = docHeight * scaleY;

                  return pw.Positioned(
                    left: pdfX,
                    bottom: pdfY,
                    child: pw.Container(
                      width: pdfWidth,
                      height: pdfHeight,
                      child: pw.Image(memoryImage, fit: pw.BoxFit.contain),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        );
      }

      final file = File(outputPath);
      await file.writeAsBytes(await pdf.save());
      return file;
    });
  }
}
