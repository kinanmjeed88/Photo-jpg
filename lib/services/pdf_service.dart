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

/// Print density used to size the embedded scans. 300 DPI is the standard
/// requirement for printed identity documents and keeps text edges sharp
/// without embedding the full camera resolution.
const double _targetDpi = 300;

/// Absolute ceiling for an embedded scan. A 300 DPI A4 page is about
/// 2480 x 3508 pixels, so this never degrades a page that legitimately fills
/// the sheet while it keeps the PDF size and peak memory bounded.
const int _maxEmbeddedEdge = 2600;

/// Smallest embedded edge worth writing; below this the crop is unreadable.
const int _minEmbeddedEdge = 600;

String _safePdfFileName(String rawName) {
  final withoutExtension = path.basenameWithoutExtension(rawName);
  final normalized = withoutExtension
      .replaceAll(RegExp(r'[^\p{L}\p{N}_ -]', unicode: true), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final safe = normalized.isEmpty ? 'scanned_document' : normalized;
  return '${safe.substring(0, math.min(safe.length, 80))}.pdf';
}

/// Decodes, applies EXIF orientation, bakes the on-screen rotation and sizes one
/// source image for embedding.
///
/// The rotation is baked into the pixels instead of being applied with a PDF
/// transform: the canvas renders rotated documents through `RotatedBox`, which
/// swaps the layout box, and only a baked rotation reproduces that layout
/// inside the fixed placed rectangle. Both operations rotate clockwise, so the
/// PDF matches the preview for 90/180/270 degree rotations.
Uint8List _preparePdfImage({
  required String sourcePath,
  required int rotationDegrees,
  required int targetLongestEdge,
}) {
  final rawBytes = File(sourcePath).readAsBytesSync();
  var image = img.decodeImage(rawBytes);
  if (image == null) {
    throw StateError('ملف الصورة غير صالح: $sourcePath');
  }
  image = img.bakeOrientation(image);
  final quarterTurns = ((rotationDegrees % 360) + 360) % 360;
  if (quarterTurns != 0) {
    image = img.copyRotate(
      image,
      angle: quarterTurns,
      interpolation: img.Interpolation.average,
    );
  }
  final boundedEdge = targetLongestEdge.clamp(
    _minEmbeddedEdge,
    _maxEmbeddedEdge,
  );
  final longestEdge = math.max(image.width, image.height);
  if (longestEdge > boundedEdge) {
    final scale = boundedEdge / longestEdge;
    image = img.copyResize(
      image,
      width: math.max(1, (image.width * scale).round()),
      height: math.max(1, (image.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}

/// Renders every page of the document inside a background isolate.
///
/// A document whose file disappeared or cannot be decoded is skipped with a
/// warning instead of failing the whole export, so one broken crop can never
/// cost the user the remaining pages.
Future<Map<String, Object>> _generatePdfInIsolate(
  Map<String, dynamic> args,
) async {
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
  final warnings = <String>[];
  var renderedDocumentCount = 0;
  var pageCount = 0;

  for (final documentsOnPage in pagesData) {
    final widgets = <pw.Widget>[];
    for (final data in documentsOnPage) {
      final sourcePath = data['path'] as String;
      try {
        final scale = data['scale'] as double;
        final left = (data['dx'] as double) * xScale;
        final top = (data['dy'] as double) * yScale;
        final width = (data['width'] as double) * scale * xScale;
        final height = (data['height'] as double) * scale * yScale;
        if (width <= 0 || height <= 0) {
          throw StateError('غير صالح: $sourcePath');
        }
        final rotation = (data['rotationAngle'] as int) % 360;
        final placedLongestEdge = math.max(width, height);
        final targetEdge = (placedLongestEdge / 72 * _targetDpi).round();
        final bytes = _preparePdfImage(
          sourcePath: sourcePath,
          rotationDegrees: rotation,
          targetLongestEdge: targetEdge,
        );
        widgets.add(
          pw.Positioned(
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
              child: pw.Image(
                pw.MemoryImage(bytes),
                fit: pw.BoxFit.contain,
              ),
            ),
          ),
        );
        renderedDocumentCount++;
      } catch (_) {
        warnings.add(
          'تعذر إدراج صورة (${path.basename(sourcePath)}) لأن ملفها غير متوفر أو غير صالح.',
        );
      }
    }
    if (widgets.isEmpty) continue;
    document.addPage(
      pw.Page(
        pageFormat: pageFormat,
        margin: pw.EdgeInsets.zero,
        build: (context) => pw.Stack(children: widgets),
      ),
    );
    pageCount++;
  }

  if (renderedDocumentCount == 0) {
    throw StateError('لا توجد صور صالحة لإنشاء ملف PDF.');
  }

  final target = File(outputPath);
  final temporary = File('$outputPath.partial');
  // Written next to the final file and renamed, so a crash mid-write can never
  // leave a half-written PDF inside the archive.
  await temporary.writeAsBytes(await document.save(), flush: true);
  if (await target.exists()) await target.delete();
  await temporary.rename(target.path);

  return <String, Object>{
    'outputPath': target.path,
    'warnings': warnings,
    'pageCount': pageCount,
    'documentCount': renderedDocumentCount,
  };
}

/// Outcome of a PDF export.
class PdfGenerationResult {
  const PdfGenerationResult({
    required this.file,
    required this.pageCount,
    required this.documentCount,
    this.warnings = const <String>[],
  });

  final File file;
  final int pageCount;
  final int documentCount;

  /// Documents that could not be embedded and were skipped.
  final List<String> warnings;
}

class PdfService {
  Future<PdfGenerationResult> generatePdf({
    required Map<int, List<ScannedDocument>> groupedPages,
    required AppState state,
    required double uiCanvasWidth,
    required double uiCanvasHeight,
  }) async {
    final directory = await getApplicationDocumentsDirectory();
    final outputPath = path.join(
      directory.path,
      _safePdfFileName(state.effectiveFileName),
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

    final result = await Isolate.run(
      () => _generatePdfInIsolate(<String, dynamic>{
        'outputPath': outputPath,
        'pagesData': pagesData,
        'uiCanvasWidth': uiCanvasWidth,
        'uiCanvasHeight': uiCanvasHeight,
        'addFrame': state.addFrame,
      }),
    );
    return PdfGenerationResult(
      file: File(result['outputPath']! as String),
      pageCount: (result['pageCount']! as num).toInt(),
      documentCount: (result['documentCount']! as num).toInt(),
      warnings: List<String>.unmodifiable(
        (result['warnings']! as List).cast<String>(),
      ),
    );
  }
}
