import 'package:opencv_dart/opencv_dart.dart' as cv;
void main() {
   var contour = cv.VecPoint.fromList([cv.Point(0,0), cv.Point(0,10), cv.Point(10,10), cv.Point(10,0)]);
   var rect = cv.minAreaRect(contour);
   print(rect);
}
