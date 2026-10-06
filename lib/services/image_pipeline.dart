import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'temporary_image_store.dart';

/// JPEG quality for work files that are written once and then re-read many
/// times (orientation normalisation). High enough to be visually lossless.
const int _normalizedQuality = 95;

/// Immutable description of the tone and sharpness adjustments applied to a
/// scanned document.
///
/// This class is the single source of truth for both rendering paths:
///
/// * the interactive preview, which renders the tone affine transform on the
///   GPU through [colorMatrix] to stay frame-accurate while a slider moves;
/// * the export path, which renders the same transform per pixel through
///   [applyToImage] inside a background isolate.
///
/// Deriving the matrix and the pixel math from the same [gain]/[offset] pair
/// removes the previous "preview looks different from the saved file" defect,
/// and keeps the transformation testable without a running Flutter engine.
@immutable
class ImageAdjustments {
  const ImageAdjustments({
    this.contrast = defaultContrast,
    this.brightness = defaultBrightness,
    this.sharpness = defaultSharpness,
  });

  /// Neutral contrast: output equals input.
  static const double defaultContrast = 1;

  /// Neutral brightness, expressed as a percentage of [midGray].
  static const double defaultBrightness = 0;

  /// Neutral sharpness: no unsharp mask is applied.
  static const double defaultSharpness = 0;

  static const double minimumContrast = 0.5;
  static const double maximumContrast = 2;
  static const double minimumBrightness = -100;
  static const double maximumBrightness = 100;
  static const double minimumSharpness = 0;
  static const double maximumSharpness = 5;

  /// Pivot of the contrast curve. `ColorFilter.matrix` operates on 0..255
  /// channel values, so its constant column must use the same scale.
  static const double midGray = 127.5;

  /// Longest edge of the preview proxy. Unsharp radii are expressed relative to
  /// this resolution so that the visual strength of the filter does not depend
  /// on whether the preview or the full-resolution export is being processed.
  static const int previewMaxEdge = 1080;

  final double contrast;
  final double brightness;
  final double sharpness;

  ImageAdjustments copyWith({
    double? contrast,
    double? brightness,
    double? sharpness,
  }) {
    return ImageAdjustments(
      contrast: contrast ?? this.contrast,
      brightness: brightness ?? this.brightness,
      sharpness: sharpness ?? this.sharpness,
    );
  }

  /// Clamps every value into its documented slider range.
  ImageAdjustments get normalized => ImageAdjustments(
    contrast: contrast.clamp(minimumContrast, maximumContrast).toDouble(),
    brightness: brightness
        .clamp(minimumBrightness, maximumBrightness)
        .toDouble(),
    sharpness: sharpness.clamp(minimumSharpness, maximumSharpness).toDouble(),
  );

  /// Multiplier applied to every colour channel.
  double get gain => normalized.contrast;

  /// Additive term applied to every colour channel, in 0..255 units.
  double get offset {
    final safe = normalized;
    return (midGray * (safe.brightness / 100)) +
        (midGray * (1 - safe.contrast));
  }

  bool get isToneIdentity => gain == 1 && offset == 0;

  bool get isIdentity => isToneIdentity && normalized.sharpness == 0;

  /// Strength of the unsharp mask in 0..1.
  double get unsharpAmount =>
      (normalized.sharpness / maximumSharpness).clamp(0.0, 1.0).toDouble();

  /// `ColorFilter.matrix` compatible 4x5 matrix.
  ///
  /// The GPU applies `channel * gain + offset` and clamps to 0..255, which is
  /// exactly the operation [applyToneInPlace] performs on the CPU.
  List<double> get colorMatrix => <double>[
    gain, 0, 0, 0, offset, //
    0, gain, 0, 0, offset, //
    0, 0, gain, 0, offset, //
    0, 0, 0, 1, 0, //
  ];

  /// Blur radius for an image whose longest edge is [longestEdge] pixels.
  ///
  /// Returns 0 when sharpening is disabled so callers can skip the extra
  /// blurred copy entirely.
  int blurRadiusFor(int longestEdge) {
    if (normalized.sharpness <= 0) return 0;
    final resolutionScale = longestEdge <= 0
        ? 1.0
        : longestEdge / previewMaxEdge;
    final radius = (normalized.sharpness / 2) * resolutionScale;
    return radius.round().clamp(1, 6);
  }

  @override
  bool operator ==(Object other) =>
      other is ImageAdjustments &&
      other.contrast == contrast &&
      other.brightness == brightness &&
      other.sharpness == sharpness;

  @override
  int get hashCode => Object.hash(contrast, brightness, sharpness);
}

/// Applies [adjustments] to a decoded image and returns a new image.
///
/// The canonical order is *sharpen then tone*. Because the unsharp mask is a
/// linear filter and the tone curve is an affine transform, the two operations
/// commute up to clamping, which is what allows the GPU preview (tone only,
/// applied to an already sharpened proxy) to match the exported file.
img.Image applyAdjustments(img.Image source, ImageAdjustments adjustments) {
  final result = img.Image.from(source);
  final safe = adjustments.normalized;
  if (safe.sharpness > 0) {
    sharpenInPlace(result, safe);
  }
  applyToneInPlace(result, safe);
  return result;
}

/// Adds an unsharp mask to [image] in place.
void sharpenInPlace(img.Image image, ImageAdjustments adjustments) {
  final amount = adjustments.unsharpAmount;
  if (amount <= 0) return;
  final radius = adjustments.blurRadiusFor(math.max(image.width, image.height));
  if (radius <= 0) return;

  final blurred = img.gaussianBlur(img.Image.from(image), radius: radius);
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final original = image.getPixel(x, y);
      final softened = blurred.getPixel(x, y);
      num sharpen(num base, num blur) =>
          (base + ((base - blur) * amount)).clamp(0, 255);
      image.setPixelRgba(
        x,
        y,
        sharpen(original.r, softened.r),
        sharpen(original.g, softened.g),
        sharpen(original.b, softened.b),
        original.a,
      );
    }
  }
}

/// Applies the affine tone curve of [adjustments] to [image] in place.
void applyToneInPlace(img.Image image, ImageAdjustments adjustments) {
  final safe = adjustments.normalized;
  if (safe.isToneIdentity) return;
  final gain = safe.gain;
  final offset = safe.offset;

  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final original = image.getPixel(x, y);
      num tone(num value) => (value * gain + offset).clamp(0, 255);
      image.setPixelRgba(
        x,
        y,
        tone(original.r),
        tone(original.g),
        tone(original.b),
        original.a,
      );
    }
  }
}

/// A crop rectangle expressed in the pixel space of a decoded image.
///
/// The manual crop screen and the image editor both work against a downscaled
/// proxy while the user interacts with the picture, but every export must crop
/// the full-resolution source. Keeping the conversion in one tested factory
/// removes duplicated (and previously divergent) rounding rules.
@immutable
class CropBounds {
  const CropBounds({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final int left;
  final int top;
  final int width;
  final int height;

  int get right => left + width;
  int get bottom => top + height;

  Map<String, int> toMap() => <String, int>{
    'left': left,
    'top': top,
    'width': width,
    'height': height,
  };

  static CropBounds? fromMap(Object? value) {
    if (value is! Map) return null;
    final left = (value['left'] as num?)?.toInt();
    final top = (value['top'] as num?)?.toInt();
    final width = (value['width'] as num?)?.toInt();
    final height = (value['height'] as num?)?.toInt();
    if (left == null || top == null || width == null || height == null) {
      return null;
    }
    if (left < 0 || top < 0 || width <= 0 || height <= 0) return null;
    return CropBounds(left: left, top: top, width: width, height: height);
  }

  /// Converts a rectangle measured in proxy pixels into source pixels.
  ///
  /// [proxyScale] is the factor that was used to downscale the source into the
  /// proxy (1 when no downscale happened). Invalid or empty rectangles return
  /// `null` instead of silently producing a one-pixel crop.
  static CropBounds? fromProxyRect({
    required Rect? rect,
    required double proxyScale,
    required int sourceWidth,
    required int sourceHeight,
  }) {
    if (rect == null || sourceWidth <= 0 || sourceHeight <= 0) return null;
    final safeScale = (proxyScale.isFinite && proxyScale > 0)
        ? proxyScale
        : 1.0;
    // An empty or sub-pixel rectangle means the editor never reported a real
    // selection. Reporting that as "no crop" is honest; rounding it up would
    // silently export a one-pixel image.
    final mappedWidth = rect.width / safeScale;
    final mappedHeight = rect.height / safeScale;
    if (!mappedWidth.isFinite ||
        !mappedHeight.isFinite ||
        mappedWidth < 1 ||
        mappedHeight < 1) {
      return null;
    }
    final left = (rect.left / safeScale).floor().clamp(0, sourceWidth - 1);
    final top = (rect.top / safeScale).floor().clamp(0, sourceHeight - 1);
    final right = (rect.right / safeScale).ceil().clamp(left + 1, sourceWidth);
    final bottom = (rect.bottom / safeScale).ceil().clamp(
      top + 1,
      sourceHeight,
    );
    final width = right - left;
    final height = bottom - top;
    if (width <= 0 || height <= 0) return null;
    return CropBounds(left: left, top: top, width: width, height: height);
  }

  /// Restricts the rectangle to an image of the given size.
  CropBounds clampTo(int imageWidth, int imageHeight) {
    if (imageWidth <= 0 || imageHeight <= 0) {
      return const CropBounds(left: 0, top: 0, width: 1, height: 1);
    }
    final safeLeft = left.clamp(0, imageWidth - 1);
    final safeTop = top.clamp(0, imageHeight - 1);
    final safeRight = right.clamp(safeLeft + 1, imageWidth);
    final safeBottom = bottom.clamp(safeTop + 1, imageHeight);
    return CropBounds(
      left: safeLeft,
      top: safeTop,
      width: safeRight - safeLeft,
      height: safeBottom - safeTop,
    );
  }

  /// Crops [image] using these bounds, clamping to the image first.
  img.Image crop(img.Image image) {
    final safe = clampTo(image.width, image.height);
    return img.copyCrop(
      image,
      x: safe.left,
      y: safe.top,
      width: safe.width,
      height: safe.height,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CropBounds &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}

/// Result of downscaling a source image into an editing proxy.
@immutable
class ImageProxy {
  const ImageProxy({required this.bytes, required this.scale});

  /// Encoded JPEG bytes of the proxy, or the untouched source when no
  /// downscale was required.
  final Uint8List bytes;

  /// Factor that maps proxy pixels back to source pixels (1 when unchanged).
  final double scale;
}

/// Decodes [encoded] and bakes any EXIF orientation into the pixels.
///
/// Decodes [encoded] and never throws.
///
/// `package:image` probes every registered format with the bytes it is given,
/// and a truncated or hostile header makes a decoder throw (`RangeError`,
/// `FormatException`, ...) instead of reporting "this is not an image". Every
/// decode of untrusted bytes in the application goes through this helper so the
/// documented contract of each entry point holds for *any* input: `null` where
/// the caller handles a missing image, [StateError] where the caller expects a
/// deterministic failure.
img.Image? decodeImageOrNull(Uint8List encoded) {
  if (encoded.isEmpty) return null;
  try {
    return img.decodeImage(encoded);
  } catch (error) {
    debugPrint('تعذر فك ترميز الصورة: $error');
    return null;
  }
}

/// Decodes [encoded] into the single "upright pixel" space the application
/// works in: what is measured here is what is displayed, what is cropped, and
/// what is embedded into the PDF.
///
/// The decoders in the stack already apply the EXIF orientation tag while
/// decoding - `package:image`'s JPEG decoder bakes the pixels and clears the
/// tag, OpenCV does it in `imread`, and the Flutter engine does it in
/// `SkPixmapUtils::Orient` - so [img.bakeOrientation] is a cheap idempotent
/// guard here, not a second rotation. Never add a compensating rotation to
/// bytes that still carry the tag: that would rotate twice.
///
/// Throws [StateError] when the bytes cannot be decoded so the caller can show a
/// deterministic error instead of an endless loading indicator.
img.Image decodeOriented(Uint8List encoded) {
  final decoded = decodeImageOrNull(encoded);
  if (decoded == null) {
    throw StateError('ملف الصورة غير صالح.');
  }
  return img.bakeOrientation(decoded);
}

/// True when [image] still carries an EXIF orientation that changes how the
/// pixels must be interpreted.
bool _hasPendingOrientation(img.Image image) {
  final ifd = image.exif.imageIfd;
  return ifd.hasOrientation && ifd.orientation != 1;
}

/// Upright dimensions of [encoded], or `null` when it cannot be decoded.
///
/// Isolate-friendly: only bytes go in and two integers come out.
(int, int)? orientedDimensionsFromBytes(Uint8List encoded) {
  final decoded = decodeImageOrNull(encoded);
  if (decoded == null) return null;
  final oriented = img.bakeOrientation(decoded);
  return (oriented.width, oriented.height);
}

/// Rewrites [file] as an upright work file when a decoder would not apply its
/// EXIF orientation; otherwise returns [file] unchanged (no re-encode).
///
/// Every stage of this application needs a single pixel grid: display, manual
/// crop, editor, PDF and gallery all have to agree on where a crop rectangle
/// lands. All decoders in the current stack do agree (they all apply EXIF), and
/// `package:image` reports the tag as already applied after decoding it, so a
/// JPEG camera frame returns unchanged here. The check stays because it is the
/// single intake guard against a decoder that ever stops applying the tag, and
/// because swapping the tag by hand - instead of this normalisation - is what
/// used to produce crop rectangles rotated by 90 degrees.
///
/// Failures are non fatal: the original file is returned so the user can keep
/// working even if the copy cannot be written.
Future<File> normalizeOrientation(File file) async {
  final path = file.path;
  try {
    final baked = await Isolate.run(() {
      final source = File(path);
      if (!source.existsSync()) return null;
      final decoded = decodeImageOrNull(source.readAsBytesSync());
      if (decoded == null || !_hasPendingOrientation(decoded)) return null;
      final upright = img.bakeOrientation(decoded);
      return Uint8List.fromList(
        img.encodeJpg(upright, quality: _normalizedQuality),
      );
    });
    if (baked == null) return file;
    return await TemporaryImageStore.writeJpeg(baked, prefix: 'upright_');
  } catch (_) {
    return file;
  }
}

/// Reads [file] and returns its upright dimensions off the UI isolate.
///
/// Returns `null` for a missing or undecodable file instead of throwing, so
/// callers can report a single, specific failure message. Only the path string
/// crosses the isolate boundary: `dart:io` handles are not sendable, and the
/// file is read inside the worker so no multi-megabyte copy is needed.
Future<(double, double)?> readOrientedDimensions(File file) async {
  final path = file.path;
  final dimensions = await Isolate.run(() {
    final target = File(path);
    if (!target.existsSync()) return null;
    return orientedDimensionsFromBytes(target.readAsBytesSync());
  });
  return dimensions == null
      ? null
      : (dimensions.$1.toDouble(), dimensions.$2.toDouble());
}

/// A preview proxy plus the upright pixel dimensions it was built from.
@immutable
class OrientedProxy {
  const OrientedProxy({
    required this.proxy,
    required this.width,
    required this.height,
  });

  final ImageProxy proxy;

  /// Dimensions of the displayed (orientation-baked) source image.
  final int width;
  final int height;
}

/// Decodes [encoded], bakes the EXIF orientation and downscales the result to a
/// preview proxy.
///
/// The original bytes are reused only when no orientation had to be baked, so
/// the proxy and the source always describe the same pixel grid. A re-encoded
/// proxy is used whenever the decoded image had to be rotated, because the
/// returned bytes must never disagree with the `width`/`height` reported here.
OrientedProxy createOrientedProxy(
  Uint8List encoded, {
  int maxEdge = ImageAdjustments.previewMaxEdge,
}) {
  final decoded = decodeImageOrNull(encoded);
  if (decoded == null) {
    throw StateError('ملف الصورة غير صالح للمعاينة.');
  }
  final needsBake = _hasPendingOrientation(decoded);
  final upright = needsBake ? img.bakeOrientation(decoded) : decoded;
  return OrientedProxy(
    proxy: _createProxyFromImage(
      upright,
      originalBytes: needsBake ? null : encoded,
      maxEdge: maxEdge,
    ),
    width: upright.width,
    height: upright.height,
  );
}

/// Builds a proxy from an already decoded image.
///
/// Private: [createOrientedProxy] is the only public entry point, so the
/// downscale rule cannot be bypassed by a caller that skipped the orientation
/// step.
///
/// [originalBytes] short-circuits the re-encode when the source already fits
/// inside [maxEdge], which keeps a second decode/encode pass out of the editor
/// startup path.
ImageProxy _createProxyFromImage(
  img.Image source, {
  Uint8List? originalBytes,
  int maxEdge = ImageAdjustments.previewMaxEdge,
}) {
  final longestEdge = math.max(source.width, source.height);
  if (longestEdge <= maxEdge) {
    return ImageProxy(bytes: originalBytes ?? encodeJpeg(source), scale: 1);
  }
  final scale = maxEdge / longestEdge;
  final proxy = img.copyResize(
    source,
    width: math.max(1, (source.width * scale).round()),
    height: math.max(1, (source.height * scale).round()),
    interpolation: img.Interpolation.average,
  );
  return ImageProxy(bytes: encodeJpeg(proxy), scale: scale);
}

/// Encodes [image] as JPEG, throwing when the encoder produced no data.
Uint8List encodeJpeg(img.Image image, {int quality = 90}) {
  final encoded = img.encodeJpg(image, quality: quality);
  if (encoded.isEmpty) {
    throw StateError('تعذر ترميز معاينة JPEG.');
  }
  return Uint8List.fromList(encoded);
}
