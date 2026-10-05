import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:doc_scanner_app/constants/app_constants.dart';
import 'package:doc_scanner_app/providers/app_state.dart';
import 'package:doc_scanner_app/services/image_pipeline.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Builds a JPEG whose EXIF block marks it as rotated 90 degrees clockwise.
///
/// The `image` package decoder bakes the orientation tag into the pixels and
/// clears it (see `bake_orientation.dart`), which is exactly what Flutter's
/// engine does as well, so this fixture feeds the same code path a real camera
/// file does.
Uint8List _rotatedJpeg(int width, int height, {int orientation = 6}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(200, 30, 30));
  image.exif.imageIfd.orientation = orientation;
  return Uint8List.fromList(img.encodeJpg(image));
}

/// Size of the marker block used by [_markedJpeg].
const int _markerSize = 4;

/// Builds a black JPEG with a red block at the pixel origin, tagged with
/// [orientation]. Used to prove that the orientation is applied exactly once.
Uint8List _markedJpeg(int width, int height, {required int orientation}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(0, 0, 0));
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: _markerSize - 1,
    y2: _markerSize - 1,
    color: img.ColorRgb8(255, 0, 0),
  );
  image.exif.imageIfd.orientation = orientation;
  return Uint8List.fromList(img.encodeJpg(image));
}

/// Marker block in the *oriented* image as `(left, top, right, bottom)`.
///
/// [sourceWidth] and [sourceHeight] are the dimensions before the orientation
/// is applied. The values follow the sampling rules the JPEG decoder uses when
/// it bakes an EXIF orientation (`_jpeg_quantize_io.dart`): applying the
/// transform twice would land the block somewhere else and fail the assertion.
(int, int, int, int) _expectedMarkerRect(
  int orientation,
  int sourceWidth,
  int sourceHeight,
) {
  final lastX = sourceWidth - 1;
  final lastY = sourceHeight - 1;
  final span = _markerSize - 1;
  switch (orientation) {
    case 3:
      return (lastX - span, lastY - span, sourceWidth, sourceHeight);
    case 6:
      return (lastY - span, 0, sourceHeight, _markerSize);
    case 8:
      return (0, lastX - span, _markerSize, sourceWidth);
    default:
      return (0, 0, _markerSize, _markerSize);
  }
}

void main() {
  group('ImageAdjustments', () {
    test('neutral values produce the identity colour matrix', () {
      const adjustments = ImageAdjustments();
      final matrix = adjustments.colorMatrix;

      expect(adjustments.isIdentity, isTrue);
      expect(matrix[0], 1);
      expect(matrix[4], 0);
      expect(matrix[6], 1);
      expect(matrix[9], 0);
      expect(matrix[12], 1);
      expect(matrix[14], 0);
    });

    test('brightness is an additive offset, contrast a multiplier', () {
      const adjustments = ImageAdjustments(contrast: 2, brightness: 50);
      final matrix = adjustments.colorMatrix;
      // offset = midGray * (brightness / 100) + midGray * (1 - contrast)
      const expectedOffset = 127.5 * 0.5 + 127.5 * (1 - 2);

      expect(matrix[0], 2);
      expect(matrix[4], closeTo(expectedOffset, 0.001));
      expect(adjustments.offset, closeTo(expectedOffset, 0.001));
      // The GPU preview and the CPU export read the same pair, which is what
      // keeps the saved file identical to what the sliders showed.
      expect(matrix[0], adjustments.gain);
      expect(matrix[4], adjustments.offset);
    });

    test('out-of-range values are clamped before use', () {
      const adjustments = ImageAdjustments(
        contrast: 99,
        brightness: -400,
        sharpness: 50,
      );

      expect(adjustments.normalized.contrast, ImageAdjustments.maximumContrast);
      expect(
        adjustments.normalized.brightness,
        ImageAdjustments.minimumBrightness,
      );
      expect(
        adjustments.normalized.sharpness,
        ImageAdjustments.maximumSharpness,
      );
      expect(adjustments.unsharpAmount, 1);
      expect(adjustments.blurRadiusFor(ImageAdjustments.previewMaxEdge), 3);
      expect(adjustments.blurRadiusFor(100000), lessThanOrEqualTo(6));
    });

    test('sharpness keeps the blur radius proportional to resolution', () {
      const adjustments = ImageAdjustments(sharpness: 4);
      final previewRadius = adjustments.blurRadiusFor(1080);
      final exportRadius = adjustments.blurRadiusFor(4320);

      expect(previewRadius, greaterThanOrEqualTo(1));
      expect(exportRadius, greaterThanOrEqualTo(previewRadius));
      expect(exportRadius, lessThanOrEqualTo(6));
    });

    test('the tone curve matches the documented gain and offset', () {
      // Four channels so the alpha assertion below is meaningful: a three
      // channel image reports alpha as 255 regardless of the source colour.
      final source = img.Image(width: 4, height: 4, numChannels: 4);
      img.fill(source, color: img.ColorRgba8(80, 80, 80, 200));
      const adjustments = ImageAdjustments(contrast: 1.5, brightness: 10);
      final processed = img.Image.from(source);
      applyToneInPlace(processed, adjustments);

      expect(
        processed.getPixel(1, 1).r,
        closeTo(80 * 1.5 + adjustments.offset, 0.6),
      );
      expect(processed.getPixel(1, 1).a, 200);
    });

    test('the unsharp mask increases local contrast', () {
      final source = img.Image(width: 6, height: 6);
      img.fill(source, color: img.ColorRgb8(60, 60, 60));
      for (var y = 0; y < source.height; y++) {
        source.setPixelRgba(3, y, 200, 200, 200, 255);
      }

      final sharpened = applyAdjustments(
        source,
        const ImageAdjustments(sharpness: 5),
      );

      expect(sharpened.getPixel(2, 3).r, lessThan(60));
      expect(sharpened.getPixel(3, 3).r, greaterThanOrEqualTo(200));
      expect(sharpened.getPixel(3, 3).a, 255);
    });
  });

  group('CropBounds', () {
    test('maps proxy pixels onto the full-resolution source', () {
      final bounds = CropBounds.fromProxyRect(
        rect: const Rect.fromLTWH(100, 50, 200, 100),
        proxyScale: 0.25,
        sourceWidth: 4000,
        sourceHeight: 3000,
      );

      expect(bounds, isNotNull);
      expect(bounds!.left, 400);
      expect(bounds.top, 200);
      expect(bounds.width, 800);
      expect(bounds.height, 400);
    });

    test('rejects empty rectangles and invalid scales', () {
      expect(
        CropBounds.fromProxyRect(
          rect: Rect.zero,
          proxyScale: 1,
          sourceWidth: 100,
          sourceHeight: 100,
        ),
        isNull,
      );
      final bounds = CropBounds.fromProxyRect(
        rect: const Rect.fromLTWH(10, 10, 20, 20),
        proxyScale: 0,
        sourceWidth: 100,
        sourceHeight: 100,
      );
      expect(bounds, isNotNull);
      expect(bounds!.left, 10);
    });

    test('clamps a rectangle that reaches past the image edge', () {
      final bounds = const CropBounds(left: 90, top: 95, width: 40, height: 40);
      final clamped = bounds.clampTo(100, 100);

      expect(clamped.right, lessThanOrEqualTo(100));
      expect(clamped.bottom, lessThanOrEqualTo(100));
      expect(clamped.width, greaterThan(0));
      expect(clamped.height, greaterThan(0));
    });

    test('round-trips through the isolate payload map', () {
      const bounds = CropBounds(left: 4, top: 8, width: 16, height: 32);
      final restored = CropBounds.fromMap(bounds.toMap());

      expect(restored, bounds);
      expect(CropBounds.fromMap(<String, Object?>{'left': -1}), isNull);
    });
  });

  group('oriented decoding', () {
    test('EXIF rotation is baked into the reported dimensions', () {
      final bytes = _rotatedJpeg(120, 80);
      final dimensions = orientedDimensionsFromBytes(bytes);

      expect(dimensions, isNotNull);
      expect(dimensions!.$1, 80);
      expect(dimensions.$2, 120);
    });

    test('undecodable bytes report null instead of throwing', () {
      expect(
        orientedDimensionsFromBytes(Uint8List.fromList(<int>[1, 2, 3, 4])),
        isNull,
      );
    });

    test('a small rotated image keeps the upright pixel grid', () {
      final bytes = _rotatedJpeg(120, 80);
      final oriented = createOrientedProxy(bytes);

      expect(oriented.width, 80);
      expect(oriented.height, 120);
      expect(oriented.proxy.scale, 1);
      // Whatever bytes the proxy keeps, every decoder that consumes them
      // reports the upright size: the editor's crop rectangle and the export
      // therefore describe the same pixels.
      final decoded = img.decodeImage(oriented.proxy.bytes)!;
      expect(decoded.width, 80);
      expect(decoded.height, 120);
    });

    test('a large image is downscaled and reports the upright size', () {
      // A portrait phone capture: landscape pixels plus an EXIF 6 tag.
      final oriented = createOrientedProxy(_rotatedJpeg(2160, 1080));

      expect(oriented.width, 1080);
      expect(oriented.height, 2160);
      expect(oriented.proxy.scale, closeTo(0.5, 0.001));
      final decoded = img.decodeImage(oriented.proxy.bytes)!;
      expect(decoded.width, lessThanOrEqualTo(ImageAdjustments.previewMaxEdge));
      expect(
        decoded.height,
        lessThanOrEqualTo(ImageAdjustments.previewMaxEdge),
      );
      expect(decoded.width, 540);
      expect(decoded.height, 1080);
    });

    test('each EXIF orientation is applied exactly once', () {
      // A marker block at the origin has to land where a single application of
      // the orientation puts it; a second application would move it elsewhere
      // and the diagonally opposite sample would no longer be dark.
      const orientations = <int>[1, 3, 6, 8];
      for (final orientation in orientations) {
        final oriented = createOrientedProxy(
          _markedJpeg(20, 10, orientation: orientation),
        );
        final quarterTurn = orientation >= 5;
        expect(
          oriented.width,
          quarterTurn ? 10 : 20,
          reason: 'width for orientation $orientation',
        );
        expect(
          oriented.height,
          quarterTurn ? 20 : 10,
          reason: 'height for orientation $orientation',
        );

        final decoded = img.decodeImage(oriented.proxy.bytes)!;
        final (left, top, right, bottom) = _expectedMarkerRect(
          orientation,
          20,
          10,
        );
        final centerX = (left + right - 1) ~/ 2;
        final centerY = (top + bottom - 1) ~/ 2;
        final marker = decoded.getPixel(centerX, centerY);
        expect(
          marker.r,
          greaterThan(150),
          reason: 'marker red channel for orientation $orientation',
        );
        expect(
          marker.g,
          lessThan(80),
          reason: 'marker green channel for orientation $orientation',
        );
        // The point diagonally opposite the marker has to be dark again.
        final opposite = decoded.getPixel(
          decoded.width - 1 - centerX,
          decoded.height - 1 - centerY,
        );
        expect(
          opposite.r,
          lessThan(80),
          reason: 'opposite corner for orientation $orientation',
        );
      }
    });

    test('normalising an intake file never changes the upright grid', () async {
      final directory = await Directory.systemTemp.createTemp('normalize_');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/rotated.jpg');
      final bytes = _rotatedJpeg(120, 80);
      await source.writeAsBytes(bytes);

      final before = orientedDimensionsFromBytes(bytes);
      final normalized = await normalizeOrientation(source);
      final after = orientedDimensionsFromBytes(await normalized.readAsBytes());

      expect(before, (80, 120));
      expect(after, before);
      // The intake guard returns the very same file when no decoder left an
      // unapplied orientation behind: no re-encode, so the tag can never be
      // applied a second time. A regression here (the tag surviving a decode)
      // would show up as a different path.
      expect(
        identical(normalized, source),
        isTrue,
        reason: 'intake must not re-encode an already upright file',
      );
    });

    test('decodeOriented rejects unusable bytes with a StateError', () {
      expect(
        () => decodeOriented(Uint8List.fromList(<int>[0, 0, 0])),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('AppConstants canvas clamping', () {
    test('keeps a small document inside the A4 guide', () {
      expect(AppConstants.clampToGuideX(-50, 100), AppConstants.kA4GuideLeft);
      final rightAligned = AppConstants.clampToGuideX(10000, 100);
      expect(
        rightAligned,
        closeTo(
          AppConstants.kVirtualCanvasWidth - AppConstants.kA4GuideLeft - 100,
          0.001,
        ),
      );
    });

    test('pins an oversized document instead of throwing', () {
      // An inverted range used to make `num.clamp` throw for documents larger
      // than the guide, which crashed the rotate and fit actions.
      expect(
        AppConstants.clampToGuideX(0, AppConstants.kVirtualCanvasWidth * 2),
        AppConstants.kA4GuideLeft,
      );
      expect(
        AppConstants.clampToGuideY(0, AppConstants.kVirtualCanvasHeight * 2),
        AppConstants.kA4GuideTop,
      );
    });
  });

  group('AppState persistence payload', () {
    test('round-trips every preference', () {
      const state = AppState(
        hasNationalId: true,
        hasPassport: true,
        displayMethod: DisplayMethod.frontOnly,
        addFrame: true,
        fileName: 'ملفي',
        smartRecognition: true,
      );

      final restored = AppState.fromJson(state.toJson());

      expect(restored.hasNationalId, isTrue);
      expect(restored.hasHousingCard, isFalse);
      expect(restored.hasPassport, isTrue);
      expect(restored.displayMethod, DisplayMethod.frontOnly);
      expect(restored.addFrame, isTrue);
      expect(restored.fileName, 'ملفي');
      expect(restored.smartRecognition, isTrue);
    });

    test('falls back safely for missing or malformed fields', () {
      final restored = AppState.fromJson(<String, Object?>{
        'displayMethod': 'notAMethod',
        'fileName': '   ',
        'addFrame': 'yes',
      });

      expect(restored.displayMethod, DisplayMethod.onePage);
      expect(restored.fileName, AppState.defaultFileName);
      expect(restored.addFrame, isFalse);
    });
  });
}
