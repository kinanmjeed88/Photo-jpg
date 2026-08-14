import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../providers/app_state.dart';

const double _a4WidthPoints = 595.275590551;
const double _a4HeightPoints = 841.88976378;

String _safePdfFileName(String rawName) {
  final withoutExtension = path.basenameWithoutExtension(rawName);
  final normalized = withoutExtension
      .replaceAll(RegExp(r'[^\p{L}\p{N}_ -]', unicode: true), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final safe = normalized.isEmpty ? 'scanned_document' : normalized;
  return '${safe.substring(0, math.min(safe.length, 80))}.pdf';
}

Uint8List _preparePdfImage(String sourcePath) {
  final rawBytes = File(sourcePath).readAsBytesSync();
  var image = img.decodeImage(rawBytes);
  if (image == null) return rawBytes;
  image = img.bakeOrientation(image);
  final longestEdge = math.max(image.width, image.height);
  if (longestEdge > 2400) {
    final scale = 2400 / longestEdge;
    image = img.copyResize(
      image,
      width: (image.width * scale).round(),
      height: (image.height * scale).round(),
      interpolation: img.Interpolation.average,
    );
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

Future<File> _generatePdfInIsolate(Map<String, dynamic> args) async {
  final outputPath = args['outputPath'] as String;
  final pagesData = (args['pagesData'] as List)
      .map((page) => (page as List).cast<Map<String, dynamic>>())
      .toList(growable: false);
  final canvasWidth = args['uiCanvasWidth'] as double;
  final canvasHeight = args['uiCanvasHeight'] as double;
  final addFrame = args['addFrame'] as bool;
  if (canvasWidth <= 0 || canvasHeight <= 0) {
    throw ArgumentError('Canvas dimensions must be positive.');
  }

  final pageFormat = PdfPageFormat(
    _a4WidthPoints,
    _a4HeightPoints,
    marginAll: 0,
  );
  final xScale = pageFormat.width / canvasWidth;
  final yScale = pageFormat.height / canvasHeight;
  final document = pw.Document();

  final renderedPages = pagesData.isEmpty
      ? <List<Map<String, dynamic>>>[<Map<String, dynamic>>[]]
      : pagesData;
  for (final documentsOnPage in renderedPages) {
    document.addPage(
      pw.Page(
        pageFormat: pageFormat,
        margin: pw.EdgeInsets.zero,
        build: (context) => pw.Stack(
          children: documentsOnPage
              .map((data) {
                final scale = data['scale'] as double;
                final left = (data['dx'] as double) * xScale;
                final top = (data['dy'] as double) * yScale;
                final width = (data['width'] as double) * scale * xScale;
                final height = (data['height'] as double) * scale * yScale;
                final rotation = (data['rotationAngle'] as int) % 360;
                pw.Widget image = pw.Image(
                  pw.MemoryImage(_preparePdfImage(data['path'] as String)),
                  fit: pw.BoxFit.contain,
                );
                if (rotation != 0) {
                  image = pw.Transform.rotate(
                    angle: rotation * math.pi / 180,
                    child: image,
                  );
                }
                return pw.Positioned(
                  left: left,
                  top: top,
                  child: pw.Container(
                    width: width,
                    height: height,
                    decoration: addFrame
                        ? pw.BoxDecoration(
                            border: pw.Border.all(
                              color: PdfColors.black,
                              width: 0.75,
                            ),
                          )
                        : null,
                    child: image,
                  ),
                );
              })
              .toList(growable: false),
        ),
      ),
    );
  }

  final target = File(outputPath);
  final temporary = File('$outputPath.partial');
  await temporary.writeAsBytes(await document.save(), flush: true);
  if (await target.exists()) await target.delete();
  return temporary.rename(target.path);
}

class PdfService {
  Future<File> generatePdf({
    required Map<int, List<ScannedDocument>> groupedPages,
    required AppState state,
    required double uiCanvasWidth,
    required double uiCanvasHeight,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final outputPath = path.join(
      directory.path,
      _safePdfFileName(state.fileName),
    );
    final pageKeys = groupedPages.keys.toList()..sort();
    final pagesData = pageKeys
        .map(
          (pageKey) => groupedPages[pageKey]!
              .map(
                (document) => <String, dynamic>{
                  'path': document.file.path,
                  'dx': document.dx,
                  'dy': document.dy,
                  'width': document.width,
                  'height': document.height,
                  'scale': document.scale,
                  'rotationAngle': document.rotationAngle,
                },
              )
              .toList(growable: false),
        )
        .toList(growable: false);

    return Isolate.run(
      () => _generatePdfInIsolate(<String, dynamic>{
        'outputPath': outputPath,
        'pagesData': pagesData,
        'uiCanvasWidth': uiCanvasWidth,
        'uiCanvasHeight': uiCanvasHeight,
        'addFrame': state.addFrame,
      }),
    );
  }
}
