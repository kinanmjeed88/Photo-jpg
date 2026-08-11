# Manual QA Steps: Pure Flutter Crop Integration

1.  **Preparation**
    *   Open the application.
    *   Tap the floating action button to add a document (e.g., via Camera).
2.  **Verify Crop Screen Trigger**
    *   After capturing/selecting a single image, verify that the application navigates directly to the new `SingleCropScreen` instead of using the native cropper.
    *   Verify the title in the AppBar is exactly `تعديل الصورة`.
3.  **Verify Aspect Ratio Functionality**
    *   Observe the aspect ratio chips at the bottom: 'Original', 'square', '3x2', '4x3', '16x9'.
    *   Tap 'square'. Verify the crop box immediately forces a 1:1 ratio.
    *   Tap '3x2'. Verify the crop box adjusts to a 3:2 ratio.
    *   Tap the selected chip again to deselect it. The crop box should become "custom" (free-form).
4.  **Verify Hitbox Slop (The 48x48 Touch Targets)**
    *   Attempt to grab a corner handle. You should NOT have to place your finger exactly on the visible pixels of the corner. Try grabbing slightly outside the visual boundary of the corner handle. It should reliably pick up the drag action due to the expanded `24.0` radius (`48px` diameter) hitboxes.
    *   Verify this behavior for all 4 corners and 4 edges.
5.  **Verify 48px Minimum Crop Size Constraint**
    *   While in free-form mode (no aspect ratio chip selected), grab a corner and shrink the crop box as small as possible.
    *   Verify that the crop box stops shrinking when it reaches roughly 48x48 pixels on the screen (the size of a standard floating action button). It should not allow you to shrink it to a 0x0 or near-invisible dot.
6.  **Verify Submission Integration**
    *   Adjust the crop box to frame the document.
    *   Tap the checkmark icon in the AppBar.
    *   Verify that the cropped image is successfully applied to the canvas/workspace.
