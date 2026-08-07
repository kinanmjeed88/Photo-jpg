# Forensic Diagnostic Report - UI/UX Merge Regressions

## 1. Defect Classification & Root Cause Analysis

### A. Layout/Sizing Violations (Oversized cards, broken aspect ratios)
*   **Defect:** Documents appear oversized on the canvas, and their aspect ratios become distorted during resizing.
*   **Root Cause:**
    *   `ScannedDocumentsNotifier.addDocument` uses a hardcoded width of `300` as a trigger for setting initial sizes instead of tracking the actual original image dimensions.
    *   `DraggableResizableDocument._documentAspectRatio` calculates the ratio dynamically based on the current state's `width` and `height`, not the inherent image aspect ratio.
*   **Exact Execution Path:**
    1.  Image picked -> `ScannerScreen._scanDocument` decodes image, sets hardcoded `docWidth = 300` and calculates `docHeight` based on decoded aspect ratio. (Lines 68-71)
    2.  `ScannedDocumentsNotifier.addDocument` is called. It checks `if (newDocWidth == 300)` and overrides `newDocWidth` and `newDocHeight` with scaled virtual values (e.g. `VIRTUAL_A4_WIDTH * 0.42`), discarding the original intrinsic dimensions. (Lines 46-59)
    3.  User drags corner -> `DraggableResizableDocument._onResizeUpdate` updates state `width` and `height`.
    4.  `_documentAspectRatio` is recalculated as `width / height`, causing the aspect ratio to stretch or squash instead of maintaining the original image's aspect ratio. (Line 45)
*   **Relevant Code Excerpt:**
    ```dart
    // lib/providers/app_state.dart
    if (newDocWidth == 300) {
        if (effectiveType == DocumentType.a4Document) {
          newDocWidth = VIRTUAL_A4_WIDTH;
        } else {
          newDocWidth = VIRTUAL_A4_WIDTH * 0.42; // default for ID cards
        }
        // ... Calculates newDocHeight based on this, NOT preserving original image bounds
    ```
    ```dart
    // lib/widgets/draggable_document.dart
    double get _documentAspectRatio {
      if (height > 0) {
        return width / height;
      }
      return 1.0;
    }
    ```
*   **Confidence Level:** High. The code explicitly shows the mathematical override of aspect ratios based on container state rather than image properties.
*   **Alternative Causes Ruled Out:** It is not a UI rendering bug in `Image.file` (which uses `BoxFit.contain`); the container *around* the image is what dictates the bounds, and those bounds are being calculated incorrectly.
*   **Files Inspected with No Issues:** `lib/services/scanner_service.dart` (correctly handles cropping), `lib/services/pdf_service.dart` (correctly renders what it is given).

### B. Fluid Drag & Drop Mechanics & Z-Indexing (Broken feedback scaling and drop offset errors)
*   **Defect:** The dragged ghost image is too large, and dropping a document causes it to snap to the top-left corner relative to the pointer, ignoring where the user grabbed it.
*   **Root Cause:**
    *   The drop calculation in `ScannerScreen` uses a fixed +12.0 padding compensation without accounting for the local offset of the drag gesture on the widget.
    *   The `Draggable` widget in `DraggableResizableDocument` renders the `feedback` at 1:1 scale (virtual canvas size), ignoring the device screen's downscale (FittedBox scaling).
*   **Exact Execution Path:**
    1.  User drags document -> `Draggable` renders `feedback` (unscaled).
    2.  User drops -> `DragTarget.onAcceptWithDetails` in `ScannerScreen` calculates coordinates.
    3.  It reads `details.offset` (global pointer position) and converts to local: `localOffset = renderBox.globalToLocal(details.offset)`.
    4.  It calculates `virtualDx = (localOffset.dx * scaleX) + 12.0;`. This sets the top-left corner (`virtualDx`) exactly to the pointer's location, ignoring the relative grab point. (Lines 185-198)
*   **Relevant Code Excerpt:**
    ```dart
    // lib/screens/scanner_screen.dart
    double virtualDx = (localOffset.dx * scaleX) + 12.0;
    double virtualDy = (localOffset.dy * scaleY) + 12.0;
    ```
*   **Confidence Level:** High. The offset mathematics are demonstrably missing the relative grab offset, and the feedback widget lacks a `Transform.scale`.
*   **Alternative Causes Ruled Out:** Not an issue with Riverpod state management; the state updates correctly, but the values it is updated *with* are mathematically wrong.
*   **Files Inspected with No Issues:** `lib/main.dart`, `lib/screens/archive_screen.dart`.

### C. Editor Live Preview Engine (Broken real-time slider reactivity, debounce, and memory safety)
*   **Defect:** The live preview lags heavily, and applying changes produces an image that doesn't match the preview.
*   **Root Cause:**
    *   The OpenCV isolate processes the full-resolution original image for real-time slider updates (sharpness), causing lag.
    *   The final save isolate (`_runEditedIsolate`) processes brightness/contrast via OpenCV, while the live preview uses Flutter's `ColorFiltered` *on top* of the sharpness isolate. The mathematical order of operations differs.
*   **Exact Execution Path:**
    1.  User moves sharpness slider -> `_onSliderChanged` debounces and calls `_generateLivePreview`.
    2.  `_runPreviewIsolate` executes: `src = cv.imdecode(bytes, cv.IMREAD_COLOR);` on the massive original bytes without downscaling.
    3.  User clicks Save -> `_applyChanges` calls `_runEditedIsolate`.
    4.  `_runEditedIsolate` applies contrast/brightness *then* sharpness. The UI preview applied sharpness (via isolate) *then* contrast/brightness (via ColorFiltered). (Lines 81-127 in `image_editor_screen.dart`)
*   **Relevant Code Excerpt:**
    ```dart
    // lib/screens/image_editor_screen.dart (Preview Isolate)
    src = cv.imdecode(bytes, cv.IMREAD_COLOR);
    // ... processes full size
    ```
*   **Confidence Level:** High. The isolate code clearly lacks downscaling, and the visual mismatch is guaranteed by the mismatched order of operations (OpenCV C/B vs Flutter Matrix C/B).
*   **Alternative Causes Ruled Out:** Not a memory leak (objects are disposed), just extremely heavy processing on 12MP images every 100ms.
*   **Files Inspected with No Issues:** `lib/services/image_enhancement_service.dart`.

---

## STAGE 1: Corrective Architecture Plan

1.  **Model Enhancement**: Add `originalWidth` and `originalHeight` to `ScannedDocument` to preserve intrinsic image bounds permanently.
2.  **Decoder Extraction**: In `ScannerScreen._scanDocument`, calculate and pass `originalWidth` and `originalHeight` explicitly to `ScannedDocument`.
3.  **Dynamic Aspect Ratio**: In `DraggableResizableDocument`, change `_documentAspectRatio` to definitively return `widget.document.originalWidth / widget.document.originalHeight`.
4.  **Layout Logic Refactor**: In `ScannedDocumentsNotifier.addDocument`, eliminate hardcoded `300` dependency. Calculate `newDocWidth` and `newDocHeight` dynamically while strictly adhering to the exact `originalAspectRatio`. Ensure bounding box calculations scale cleanly to `VIRTUAL_A4_WIDTH`.
