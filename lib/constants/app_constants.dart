import 'dart:math' as math;

class AppConstants {
  static const double kVirtualCanvasWidth = 400.0;
  static const double kVirtualCanvasHeight = 565.6; // 400.0 * 1.414

  /// View-only A4 guide values. PDF mapping still uses the full canvas.
  static const double kA4PreviewInset = 10.0;
  static const double kA4AspectRatio = 595.28 / 841.89;
  static const double kA4GuideWidth =
      kVirtualCanvasWidth - (kA4PreviewInset * 2);
  static const double kA4GuideHeight = kA4GuideWidth / kA4AspectRatio;
  static const double kA4GuideLeft = kA4PreviewInset;
  static const double kA4GuideTop = (kVirtualCanvasHeight - kA4GuideHeight) / 2;

  /// Horizontal offset for an item of [contentWidth] virtual pixels.
  ///
  /// The result is always a valid interval: an item that is wider than the A4
  /// guide is pinned to the guide's left edge instead of producing an inverted
  /// range (`num.clamp` throws when its lower bound is greater than its upper
  /// bound, which used to crash the rotate/fit actions for large documents).
  static double clampToGuideX(double dx, double contentWidth) {
    final maxX = math.max(
      kA4GuideLeft,
      kVirtualCanvasWidth - kA4GuideLeft - contentWidth,
    );
    return dx.clamp(kA4GuideLeft, maxX).toDouble();
  }

  /// Vertical counterpart of [clampToGuideX].
  static double clampToGuideY(double dy, double contentHeight) {
    final maxY = math.max(
      kA4GuideTop,
      kVirtualCanvasHeight - kA4GuideTop - contentHeight,
    );
    return dy.clamp(kA4GuideTop, maxY).toDouble();
  }
}
