import 'dart:io';
import 'dart:isolate';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import '../providers/app_state.dart';

Future<File> _isolateGeneratePdf(Map<String, dynamic> args) async {
  final String outputPath = args['outputPath'];
  final List<Map<String, dynamic>> docData = List<Map<String, dynamic>>.from(args['docData']);
  final double uiReferenceWidth = args['uiCanvasWidth'] as double;
  final double uiReferenceHeight = args['uiCanvasHeight'] as double;

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

  // Calculate scaling based on UI reference dimensions explicitly provided
  final scaleX = pdfA4Width / uiReferenceWidth;
  final scaleY = pdfA4Height / uiReferenceHeight;

  for (var pageIndex in sortedPageIndices) {
    final docsOnPage = pagesData[pageIndex]!;

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero, // Crucial for perfect origin alignment
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
}


class PdfService {
  Future<File> generatePdf({
    required List<ScannedDocument> scannedDocuments,
    required AppState state,
    required double uiCanvasWidth,
    required double uiCanvasHeight,
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

    final args = {
      'outputPath': outputPath,
      'docData': docData,
      'uiCanvasWidth': uiCanvasWidth,
      'uiCanvasHeight': uiCanvasHeight,
    };

    return await Isolate.run(() => _isolateGeneratePdf(args));
  }
}
