import 'dart:io';
import 'dart:isolate';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import '../providers/app_state.dart';

Future<File> _isolateGeneratePdf(Map<String, dynamic> args) async {
  final String outputPath = args['outputPath'];
  // Now passing a list of pages, where each page is a list of maps (docs)
  final List<dynamic> rawPagesData = args['pagesData'];

  final List<List<Map<String, dynamic>>> pagesData = rawPagesData.map((page) {
    return List<Map<String, dynamic>>.from(page as List<dynamic>);
  }).toList();

  final double uiReferenceWidth = args['uiCanvasWidth'] as double;
  final double uiReferenceHeight = args['uiCanvasHeight'] as double;
  final bool addFrame = args['addFrame'] as bool? ?? false;

  final pdf = pw.Document();

  // UI coordinates vs PDF coordinates mapping
  // UI assumes aspect ratio 1 / 1.414, we need to map to PdfPageFormat.a4
  final pdfA4Width = PdfPageFormat.a4.width;
  final pdfA4Height = PdfPageFormat.a4.height;

  // Calculate scaling based on UI reference dimensions explicitly provided
  final scaleX = pdfA4Width / uiReferenceWidth;
  final scaleY = pdfA4Height / uiReferenceHeight;

  for (final docsOnPage in pagesData) {
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero, // Crucial for perfect origin alignment
        build: (pw.Context context) {
          return pw.Stack(
            children: docsOnPage.map((docData) {
              final String path = docData['path'] as String;
              // UI coordinates
              final double dx = docData['dx'] as double;
              final double dy = docData['dy'] as double;
              final double docWidth = docData['width'] as double;
              final double docHeight = docData['height'] as double;

              final memoryImage = pw.MemoryImage(File(path).readAsBytesSync());

              // PDF origin is bottom-left, UI origin is top-left
              final pdfX = dx * scaleX;
              // Correct Y-axis mapping: pdfY goes from bottom up.
              // Top-left of the document in UI corresponds to top-left in PDF.
              // We need the bottom coordinate of the document in PDF space.
              final pdfY = pdfA4Height - ((dy + docHeight) * scaleY);

              final pdfWidth = docWidth * scaleX;
              final pdfHeight = docHeight * scaleY;

              return pw.Positioned(
                left: pdfX,
                bottom: pdfY,
                child: pw.Container(
                  width: pdfWidth,
                  height: pdfHeight,
                  decoration: addFrame
                      ? pw.BoxDecoration(border: pw.Border.all(color: PdfColors.black, width: 1.0))
                      : null,
                  child: pw.Image(memoryImage, fit: pw.BoxFit.contain),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }

  // If there are no pages, at least add one empty page so it doesn't crash
  if (pagesData.isEmpty) {
    pdf.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      build: (pw.Context context) => pw.Container()
    ));
  }

  final file = File(outputPath);
  await file.writeAsBytes(await pdf.save());
  return file;
}

class PdfService {
  Future<File> generatePdf({
    required Map<int, List<ScannedDocument>> groupedPages,
    required AppState state,
    required double uiCanvasWidth,
    required double uiCanvasHeight,
  }) async {
    final output = await getApplicationDocumentsDirectory();
    final outputPath = '${output.path}/${state.fileName}.pdf';

    // Map document data to primitives to pass to the isolate securely
    final List<List<Map<String, dynamic>>> pagesData = [];
    final keys = groupedPages.keys.toList()..sort();

    for (var key in keys) {
      final docs = groupedPages[key]!;
      pagesData.add(docs.map((doc) => {
        'path': doc.file.path,
        'dx': doc.dx,
        'dy': doc.dy,
        'width': doc.width,
        'height': doc.height,
      }).toList());
    }

    final args = {
      'outputPath': outputPath,
      'pagesData': pagesData,
      'uiCanvasWidth': uiCanvasWidth,
      'uiCanvasHeight': uiCanvasHeight,
      'addFrame': state.addFrame,
    };

    return await Isolate.run(() => _isolateGeneratePdf(args));
  }
}
