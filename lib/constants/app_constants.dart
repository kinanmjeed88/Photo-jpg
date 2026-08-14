class AppConstants {
  static const double kVirtualCanvasWidth = 400.0;
  static const double kVirtualCanvasHeight = 565.6; // 400.0 * 1.414
  static const double kDocumentVisualPadding = 12.0;
  static const double kDocumentVisualPaddingTotal = 24.0; // 12.0 * 2

  /// View-only A4 guide values. PDF mapping still uses the full canvas.
  static const double kA4PreviewInset = 10.0;
  static const double kA4AspectRatio = 595.28 / 841.89;
  static const double kA4GuideWidth =
      kVirtualCanvasWidth - (kA4PreviewInset * 2);
  static const double kA4GuideHeight = kA4GuideWidth / kA4AspectRatio;
  static const double kA4GuideLeft = kA4PreviewInset;
  static const double kA4GuideTop = (kVirtualCanvasHeight - kA4GuideHeight) / 2;
}
