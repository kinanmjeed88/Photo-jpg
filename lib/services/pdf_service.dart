import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
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

  final pageFormat = PdfPageFormat(uiReferenceWidth, uiReferenceHeight, marginAll: 0);

  for (final docsOnPage in pagesData) {
    pdf.addPage(
      pw.Page(
        pageFormat: pageFormat,
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
              final int rotationAngle = docData['rotationAngle'] as int? ?? 0;

              // High-fidelity image processing with memory safety
              final Uint8List rawBytes = File(path).readAsBytesSync();
              img.Image? decodedImage = img.decodeImage(rawBytes);

              Uint8List processedBytes = rawBytes;

              if (decodedImage != null) {
                // EXIF Orientation fix
                decodedImage = img.bakeOrientation(decodedImage);

                // RAM safety: scale down only if longest edge exceeds 2400px
                final int maxEdge = math.max(decodedImage.width, decodedImage.height);
                if (maxEdge > 2400) {
                  final double scale = 2400 / maxEdge;
                  decodedImage = img.copyResize(
                    decodedImage,
                    width: (decodedImage.width * scale).toInt(),
                    height: (decodedImage.height * scale).toInt(),
                    interpolation: img.Interpolation.linear,
                  );
                }

                // Keep 95% quality for high-res output
                processedBytes = Uint8List.fromList(img.encodeJpg(decodedImage, quality: 95));
              }

              final memoryImage = pw.MemoryImage(processedBytes);

              // PDF origin is bottom-left, UI origin is top-left
              final pdfX = dx;
              // Correct Y-axis mapping: pdfY goes from bottom up.
              // Top-left of the document in UI corresponds to top-left in PDF.
              // We need the bottom coordinate of the document in PDF space.
              final pdfY = uiReferenceHeight - (dy + docHeight);

              pw.Widget imageWidget = pw.Image(memoryImage, fit: pw.BoxFit.contain);

              if (rotationAngle != 0) {
                // PDF rotate rotates around its center and takes angle in radians
                imageWidget = pw.Transform.rotate(
                  angle: -rotationAngle * math.pi / 180,
                  child: imageWidget,
                );
              }

              return pw.Positioned(
                left: pdfX,
                bottom: pdfY,
                child: pw.Container(
                  width: docWidth,
                  height: docHeight,
                  decoration: addFrame
                      ? pw.BoxDecoration(border: pw.Border.all(color: PdfColors.black, width: 1.0))
                      : null,
                  child: imageWidget,
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
      pageFormat: pageFormat,
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
        'rotationAngle': doc.rotationAngle,
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
