import re

with open('lib/services/scanner_service.dart', 'r') as f:
    content = f.read()

# Fix 1 & 2: Pure Color Extraction & Bulletproof Contour Fallback
# We need to change the area limit, the contour logic, and the extraction logic.
old_contour_logic = """
    for (var contour in contours) {
      final area = cv.contourArea(contour);
      // Area Filter: 3% to 50%
      if (area < imageArea * 0.03 || area > imageArea * 0.50) {
        continue;
      }

      final double peri = cv.arcLength(contour, true);
      // Shape Filter: Exactly 4 points
      final cv.VecPoint approx = cv.approxPolyDP(contour, 0.02 * peri, true);

      if (approx.length == 4) {
        final cv.Rect rect = cv.boundingRect(approx);

        // Aspect Ratio Filter (1.35 to 1.75) using max/min of bounding box
        double w = rect.width.toDouble();
        double h = rect.height.toDouble();
        double maxDim = w > h ? w : h;
        double minDim = w < h ? w : h;
        double ratio = maxDim / minDim;

        if (ratio >= 1.35 && ratio <= 1.75) {
          final orderedPts = _orderPoints(approx);
          var p0 = orderedPts[0];
          var p1 = orderedPts[1];
          var p2 = orderedPts[2];
          var p3 = orderedPts[3];

          int widthA = (p2.x - p3.x).abs();
          int widthB = (p1.x - p0.x).abs();
          int maxWidth = widthA > widthB ? widthA : widthB;

          int heightA = (p1.y - p2.y).abs();
          int heightB = (p0.y - p3.y).abs();
          int maxHeight = heightA > heightB ? heightA : heightB;

          final dstPts = cv.VecPoint.fromList([
            cv.Point(0, 0),
            cv.Point(maxWidth - 1, 0),
            cv.Point(maxWidth - 1, maxHeight - 1),
            cv.Point(0, maxHeight - 1),
          ]);

          final transMat = cv.getPerspectiveTransform(orderedPts, dstPts);
          final warped = cv.warpPerspective(srcClone, transMat, (maxWidth, maxHeight));

          // 4. Enhancement Filter (Post-Crop)
          final warpedGray = cv.cvtColor(warped, cv.COLOR_BGR2GRAY);
          final clahe = cv.CLAHE.empty();
          final claheMat = clahe.apply(warpedGray);

          final croppedPath = '$tempPath/smart_cropped_${DateTime.now().millisecondsSinceEpoch}_$count.jpg';
          cv.imwrite(croppedPath, claheMat);
          croppedFiles.add(File(croppedPath));

          claheMat.dispose();
          clahe.dispose();
          warpedGray.dispose();
          warped.dispose();
          transMat.dispose();
          dstPts.dispose();
          orderedPts.dispose();

          count++;
        }
      }
      approx.dispose();
    }
"""

new_contour_logic = """
    for (var contour in contours) {
      final area = cv.contourArea(contour);
      // Area Filter: 1.5% to 85%
      if (area < imageArea * 0.015 || area > imageArea * 0.85) {
        continue;
      }

      final double peri = cv.arcLength(contour, true);
      // Shape Filter: Exactly 4 points
      final cv.VecPoint approx = cv.approxPolyDP(contour, 0.02 * peri, true);

      cv.VecPoint orderedPts;
      bool isValidShape = false;

      if (approx.length == 4) {
        orderedPts = _orderPoints(approx);
        isValidShape = true;
      } else {
        // Fallback to minAreaRect for rounded corners / close placement
        final rect = cv.minAreaRect(contour);
        final boxPts = cv.boxPoints(rect);
        final ptsList = [
          cv.Point(boxPts[0].x.toInt(), boxPts[0].y.toInt()),
          cv.Point(boxPts[1].x.toInt(), boxPts[1].y.toInt()),
          cv.Point(boxPts[2].x.toInt(), boxPts[2].y.toInt()),
          cv.Point(boxPts[3].x.toInt(), boxPts[3].y.toInt()),
        ];
        final tempVec = cv.VecPoint.fromList(ptsList);
        orderedPts = _orderPoints(tempVec);
        tempVec.dispose();
        isValidShape = true;
      }

      if (isValidShape) {
        final cv.Rect rect = cv.boundingRect(contour); // Use original contour for bounding rect

        // Aspect Ratio Filter (1.2 to 1.9) using max/min of bounding box
        double w = rect.width.toDouble();
        double h = rect.height.toDouble();
        double maxDim = w > h ? w : h;
        double minDim = w < h ? w : h;
        double ratio = maxDim / minDim;

        if (ratio >= 1.2 && ratio <= 1.9) {
          var p0 = orderedPts[0];
          var p1 = orderedPts[1];
          var p2 = orderedPts[2];
          var p3 = orderedPts[3];

          int widthA = (p2.x - p3.x).abs();
          int widthB = (p1.x - p0.x).abs();
          int maxWidth = widthA > widthB ? widthA : widthB;

          int heightA = (p1.y - p2.y).abs();
          int heightB = (p0.y - p3.y).abs();
          int maxHeight = heightA > heightB ? heightA : heightB;

          final dstPts = cv.VecPoint.fromList([
            cv.Point(0, 0),
            cv.Point(maxWidth - 1, 0),
            cv.Point(maxWidth - 1, maxHeight - 1),
            cv.Point(0, maxHeight - 1),
          ]);

          final transMat = cv.getPerspectiveTransform(orderedPts, dstPts);
          // Apply warpPerspective EXCLUSIVELY on srcClone (Original Color Image)
          final warped = cv.warpPerspective(srcClone, transMat, (maxWidth, maxHeight));

          final croppedPath = '$tempPath/smart_cropped_${DateTime.now().millisecondsSinceEpoch}_$count.jpg';
          cv.imwrite(croppedPath, warped); // Save original color without Grayscale/CLAHE applied to final output
          croppedFiles.add(File(croppedPath));

          warped.dispose();
          transMat.dispose();
          dstPts.dispose();
          orderedPts.dispose();

          count++;
        }
      }
      approx.dispose();
    }
"""

content = content.replace(old_contour_logic.strip(), new_contour_logic.strip())

# Fix 3: Smart Manual Cropper Fallback
# "If the automatic CV pipeline finishes and croppedFiles.isEmpty... invoke existing ImageCropper().cropImage() UI"
# This needs to be done in ScannerScreen since ImageCropper requires UI context. Wait, ImageCropper can be run without context. Let's see how `scanDocument` uses it.

with open('lib/services/scanner_service.dart', 'w') as f:
    f.write(content)
