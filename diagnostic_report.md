# تقرير تشخيصي شامل - مشكلة عدم ظهور الأزرار العائمة

بناءً على طلبك، قمت بوضع نفسي في وضع التحقيق والتشخيص، وراجعت الكود بالكامل لفهم المشكلة. إليك التقرير المفصل:

### 1. فحص ملف الشاشة الرئيسي
- **الملف المسؤول**: `lib/screens/scanner_screen.dart`
- **متغير التتبع (State Variable)**: يوجد فعلاً متغير يستخدم لتتبع الصورة المحددة وهو `_selectionNotifier` من نوع `ValueNotifier<({int? pageIndex, int? docIndex})>`.
- **القيمة الافتراضية**: `(pageIndex: null, docIndex: null)`
- **التحديث عند النقر**: نعم، يتم تحديثه عند النقر على الصورة أو الشاشة. إذا تم النقر على الخلفية الفارغة يتم إرجاع القيم إلى `null`. وإذا تم النقر على الصورة، يتم التحديث بـ `pageKey` للـ pageIndex والاندكس الخاص بالصورة `docIndex`.
- **مقتطف الكود**:
```dart
// تعريف المتغير
final ValueNotifier<({int? pageIndex, int? docIndex})> _selectionNotifier = ValueNotifier((pageIndex: null, docIndex: null));

// التحديث عند النقر على الصورة (في ScannerScreen)
onTap: () {
  int actualIndex = docIndex;
  // ... منطق العثور على الـ actualIndex ...
  if (selection.pageIndex != pageKey || selection.docIndex != actualIndex) {
    ref.read(scannedDocumentsProvider.notifier).moveDocumentToTop(pageKey, actualIndex);
    final currentDocsCount = ref.read(scannedDocumentsProvider)[pageKey]?.length ?? 0;
    _selectionNotifier.value = (pageIndex: pageKey, docIndex: currentDocsCount > 0 ? currentDocsCount - 1 : actualIndex);
  }
}
```

### 2. فحص الأزرار العائمة
- **هل يوجد كود للأزرار؟**: نعم، الكود موجود.
- **مكان الكود**: ملف `lib/widgets/draggable_document.dart`
- **التصميم**: هي جزء من مكون (Component) `DraggableResizableDocument` وتتكون في دالة `_buildToolbarPill()`.
- **شرط الظهور**: تعتمد على المتغير `widget.isSelected` وأيضاً على حالة السحب `isDragging`.

### 3. فحص منطق الظهور والإخفاء
- **الشرط المكتوب**:
```dart
bottom: (widget.isSelected && !isDragging) ? -70 : -110,
opacity: (widget.isSelected && !isDragging) ? 1.0 : 0.0,
```
- **هل يتحقق الشرط؟**: نعم، عندما ننقر على الصورة، `_selectionNotifier` يتم تحديثه، والذي يمرر `isSelected = true` للـ `DraggableResizableDocument`. والدليل على ذلك أن الحدود الزرقاء (border) تظهر فعلاً (لأنها تعتمد على نفس الشرط).
- **هل هناك تعارض؟**: لا يبدو أن هناك تعارضا في منطق الشروط نفسه. ولا يوجد كود يخفي الأزرار مباشرة بعد ظهورها ما لم يقم المستخدم بالسحب.

### 4. فحص z-index والتداخل (المشكلة الحقيقية)
- **هل لها z-index كافي؟**: الـ `DraggableResizableDocument` داخل `Stack` في الشاشة الرئيسية.
- **التغطية (Overlay) والعناصر المحيطة**: هنا تكمن المشكلة. الأزرار العائمة موجودة كـ `AnimatedPositioned` وتتموضع بـ `bottom: -70` (خارج حدود عنصر الصورة الأساسي).
- **القيود المفروضة على الحجم**: الـ `DraggableResizableDocument` يعيد عنصر بحجم محدد سلفاً `SizedBox(width: width, height: totalHeight)`. المشكلة أن `totalHeight` يحسب كالتالي:
`final double totalHeight = height + (widget.isSelected ? toolbarHeight : 0);`
ويتم وضع الأزرار في `AnimatedPositioned`، ولكن الحاوي الأب في `ScannerScreen` يحوي `FittedBox(fit: BoxFit.contain, clipBehavior: Clip.none, child: SizedBox(width: AppConstants.kVirtualCanvasWidth, height: AppConstants.kVirtualCanvasHeight ...))`.
والمشكلة الأهم أن الـ `Stack` المحيط بالصورة والأزرار نفسها قد يكون مقيداً من حاويات أخرى بالرغم من وجود `Clip.none`.

### 5. فحص التنسيق (Styling)
- العرض والارتفاع محدد للأزرار `SizedBox(width: 48, height: 48)` وحاوية الأزرار لها ارتفاع `70`.
- الـ `opacity` يتغير بناءً على حالة `isSelected` بشكل صحيح من 0 إلى 1.
- المشكلة هي أن تموضع الـ `AnimatedPositioned` خارج حدود الـ `documentWidget` باستخدام `bottom: -70` قد يؤدي إلى اقتصاصه أو إخفائه تحت عناصر أخرى في الـ `ListView` في الشاشة الأساسية، خاصة وأن `Clip.none` يجب أن يكون متواجداً في كل التسلسل الهرمي.
- من الكود في `draggable_document.dart` نرى:
```dart
Widget documentWidget = SizedBox(
  width: width,
  height: totalHeight,
  child: Stack(
    clipBehavior: Clip.none,
    // ...
```
ثم:
```dart
return Positioned(
  left: dx,
  top: dy,
  child: RepaintBoundary(
    child: GestureDetector(
      // ...
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          documentWidget,
          AnimatedPositioned(
            bottom: (widget.isSelected && !isDragging) ? -70 : -110,
// ...
```
التموضع `bottom: -70` سيضع الأزرار خارج الحاوية. في نفس الوقت، الأزرار متموضعة بالنسبة للـ `Stack` الثاني، وليس لـ `documentWidget`.

### 6. فحص الأحداث (Events)
- الـ `onTap` يعمل ويُمرّر الحالة بشكل صحيح بدليل ظهور الـ border الأزرق.

### 7. الملفات ذات العلاقة
- `lib/screens/scanner_screen.dart` (ملف الشاشة الرئيسية وإدارة الحالة `_selectionNotifier`).
- `lib/widgets/draggable_document.dart` (الملف الذي يعرض الصورة والأزرار العائمة).

### 8. التشخيص النهائي

📁 **الملفات المفحوصة**:
- `lib/screens/scanner_screen.dart`
- `lib/widgets/draggable_document.dart`

🔴 **المشاكل المكتشفة**:
1. موضع الأزرار في `AnimatedPositioned` يتم باستخدام `bottom: -70` بالنسبة للـ `Stack` الأب. وبما أن الـ `Positioned` الذي يحمل هذا الـ `Stack` يتم تحديد إحداثياته عبر `left: dx, top: dy` ولا يملك قيودًا صريحة (constraints) بحجم معين (يأخذ حجم محتوياته)، فإن `bottom: -70` ستحاول وضع الأزرار أسفل الحدود السفلية للعنصر. إذا كان حجم الـ `Stack` الأب لا يأخذ في الحسبان المساحة الزائدة، فإن العناصر خارج حدوده قد تظهر، ولكن هناك حاويات أعلى في التسلسل (مثل الـ `FittedBox` أو الـ `Container` داخل الـ `ListView.separated` في `ScannerScreen`) التي قد لا تتعامل بشكل صحيح مع العناصر التي تتدفق خارج حدود `SizedBox(width: AppConstants.kVirtualCanvasWidth, height: AppConstants.kVirtualCanvasHeight)`.
2. في الـ `FittedBox`، الحاوية الأب تأخذ مقاس `AppConstants.kVirtualCanvasHeight`. إذا كان العنصر قريبًا من حافة الـ Canvas، فإن `bottom: -70` ستجعله يخرج خارج الـ Canvas تمامًا. قد تقوم الـ `Container` الأب الذي يحمل خلفية بيضاء (`color: Colors.white`) في `ScannerScreen` باقتصاص المحتوى الذي يتجاوزه (بسبب الافتقار إلى `clipBehavior: Clip.none` في بعض الحاويات في الأعلى أو بسبب قيود الـ Box).

🟡 **نقاط مشبوهة تحتاج تأكيد**:
- تأكد من الـ Container الموجود بداخل الـ ListView في `scanner_screen.dart`، في السطر 429:
```dart
return Center(
  child: Container(
    clipBehavior: Clip.none,
    // ...
```
يبدو أنه يحتوي على `clipBehavior: Clip.none` وهو جيد.
لكن ماذا عن `RepaintBoundary` في `draggable_document.dart`؟ الـ `RepaintBoundary` قد يقوم أحيانًا باقتصاص المحتوى الزائد بناءً على حجمه الأساسي!

🟢 **أشياء تعمل بشكل صحيح**:
- إدارة الحالة (`_selectionNotifier`) تعمل وتحدث الواجهة.
- يتم التعرف على الصورة كمحددة ويتم رسم الحدود الزرقاء (border) بنجاح.

🎯 **السبب الجذري**:
السبب الأرجح هو أن عنصر الـ `RepaintBoundary` الذي يغلف الصورة والأزرار يقوم باقتصاص الأزرار العائمة لأنها تقع في إحداثيات سلبية (`bottom: -70`) خارج الحدود الأصلية التي رسمها `documentWidget`. الـ `RepaintBoundary` يرسم محتواه في طبقة منفصلة (Layer)، وعادة ما يتحدد حجمها بحجم العناصر داخلها. وعندما نستخدم وضع `AnimatedPositioned` خارج هذا الحجم الأساسي، فإنه قد يُقص (clipped). بالإضافة إلى ذلك، وضع الأزرار بـ `bottom: -70` مع `AnimatedPositioned` بدون تحديد ارتفاع صريح للـ `Stack` الأب يجعله يعتمد فقط على حجم `documentWidget`، ووجود الـ `bottom` بالسالب سيجعله خارج الـ Box الأساسي للرسم الخاص بـ `RepaintBoundary` (والذي يعتمد على حجم الـ GestureDetector / Stack).

📍 **موقع المشكلة بالضبط**:
- ملف: `lib/widgets/draggable_document.dart`
- سطر: 251-255 (مكان الـ `AnimatedPositioned`)
- وتحديداً إحاطتها بـ `RepaintBoundary` في سطر 240.
