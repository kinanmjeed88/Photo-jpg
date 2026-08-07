# Plan

## 1. Rendering Integrity & Canvas Layout
- `lib/providers/app_state.dart`: Modify `addDocument` to accept the actual document width and height (from `scanner_screen.dart` decoding) instead of hardcoding `0.42 * VIRTUAL_A4_WIDTH` and enforcing fixed aspect ratios. Calculate layout based on actual aspect ratio while keeping maximum dimension constraints (e.g., width max 90% of page if portrait). Remove the hardcoded fixed 1.58 or 1.408 ratios.
- `lib/widgets/draggable_document.dart`: Remove `_documentAspectRatio` hardcoded getter. Use the actual `width/height` of the document as the aspect ratio in `AspectRatio` widget. Change `BoxFit.fill` to `BoxFit.contain` just in case, but keeping the aspect ratio matching `width/height` perfectly means `fill` will not distort it.
- **Multi-Document Layout**: Improve `addDocument` logic to actually check if the next document fits on the page (by accumulating `currentDx`, `currentDy` + heights/widths) instead of blindly assuming a 2x2 grid fits (since sizes are now dynamic).

## 2. Drag & Drop Fluidity and Z-Indexing
- `lib/widgets/draggable_document.dart`:
  - Replace `Draggable` and `DragTarget` with a stateful `GestureDetector` on `onPanStart`, `onPanUpdate`, `onPanEnd`.
  - Update `dx`, `dy` locally in `setState` for 60fps drag.
  - On `onPanEnd`, dispatch `onLayoutUpdate` to persist position to Riverpod.
  - Add `onPanStart` callback to `DraggableResizableDocument` to trigger `bringToFront` logic in `scanner_screen.dart`.
- `lib/screens/scanner_screen.dart`:
  - Provide an active document sorting/re-ordering mechanism inside `pageDocs` when an item is dragged so it renders on top. Alternatively, `DraggableResizableDocument` with local drag logic eliminates the drag lag since `Draggable` uses an overlay that can have sub-pixel offsets. Wait, cross-page drag-and-drop requires `Draggable` across multiple pages in a `ListView`.
  - Wait! "Interactive canvas elements (like draggable documents) implement cross-page free drag-and-drop using Flutter's `Draggable` and `DragTarget`. Avoid local `GestureDetector` pan updates for moving elements to prevent gesture conflicts with the drag-and-drop architecture." -> **MEMORY CONSTRAINT**.
  - So I *MUST* keep `Draggable`. To fix the lag and drop inaccuracy:
    - Lag fix: Do NOT update state globally on `onDragUpdate`. (The current code doesn't have `onDragUpdate` actually, it just has `onDragEnd`, wait, `scanner_screen.dart` uses `onAcceptWithDetails` which might be calculating drop offsets incorrectly).
    - In `scanner_screen.dart`: When `onAcceptWithDetails` fires, calculate the offset exactly. The issue is `localOffset = renderBox.globalToLocal(details.offset);` and `details.offset` is the top-left of the draggable. The drop position error is because `details.offset` includes the drag handle offset inside the widget or some padding.
    - Also, Z-Indexing: When dragging, `childWhenDragging` is an `Opacity` which leaves the original widget there. The dropped widget should be moved to the end of the list. We need to order the items.

## 3. Editor Live Preview Engine
- `lib/screens/image_editor_screen.dart`:
  - Add `ValueNotifier` or local state for the live `Uint8List` image preview instead of the `ExtendedImage.file`.
  - Implement a `Debouncer` or `Timer` in the slider `onChanged`.
  - On debounce (e.g. 100ms), spawn a new Isolate `compute` that takes the `bytes`, `brightness`, `contrast`, and `sharpness` and returns a processed `Uint8List`.
  - Ensure previous Isolates are cancelled if possible (using `Isolate.spawn` with a `ReceivePort` and keeping track of the `Isolate` object to `.kill()` it, or just use a generation counter/ID to discard old results).
  - Memory safety: Ensure `cv.Mat` are properly disposed in the isolate. (Already mostly handled in `_runEditedIsolate`).
