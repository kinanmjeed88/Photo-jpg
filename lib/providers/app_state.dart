import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum WorkMode { single, family }
enum DisplayMethod { onePage, twoPages, frontOnly }
enum DocumentType { nationalId, housingCard, rationCard, passport, unknown }

class ScannedDocument {
  final File file;
  final DocumentType type;
  final double dx;
  final double dy;
  final double width;
  final double height;

  ScannedDocument({
    required this.file,
    this.type = DocumentType.unknown,
    this.dx = 20,
    this.dy = 20,
    this.width = 300,
    this.height = 400,
  });

  ScannedDocument copyWith({
    File? file,
    DocumentType? type,
    double? dx,
    double? dy,
    double? width,
    double? height,
  }) {
    return ScannedDocument(
      file: file ?? this.file,
      type: type ?? this.type,
      dx: dx ?? this.dx,
      dy: dy ?? this.dy,
      width: width ?? this.width,
      height: height ?? this.height,
    );
  }
}

class PageModel {
  final List<ScannedDocument> documents;

  PageModel({this.documents = const []});

  PageModel copyWith({List<ScannedDocument>? documents}) {
    return PageModel(
      documents: documents ?? this.documents,
    );
  }
}

class ScannedDocumentsNotifier extends Notifier<List<PageModel>> {
  @override
  List<PageModel> build() => [];

  void addDocument(ScannedDocument doc) {
    const double canvasWidth = 380.0;
    const double canvasHeight = 537.32; // 380 * 1.414

    double forcedWidth = canvasWidth * 0.45;
    double aspectRatio = doc.height == 0 ? 1 : doc.width / doc.height;
    double forcedHeight = forcedWidth / aspectRatio;

    const double margin = 20.0;

    if (state.isEmpty) {
      double newDx = math.max(0.0, math.min(doc.dx, canvasWidth - forcedWidth));
      double newDy = math.max(0.0, math.min(doc.dy, canvasHeight - forcedHeight));

      final newDoc = doc.copyWith(dx: newDx, dy: newDy, width: forcedWidth, height: forcedHeight);
      state = [PageModel(documents: [newDoc])];
      return;
    }

    final lastPageIndex = state.length - 1;
    final lastPage = state[lastPageIndex];

    if (lastPage.documents.isEmpty) {
      double newDx = math.max(0.0, math.min(doc.dx, canvasWidth - forcedWidth));
      double newDy = math.max(0.0, math.min(doc.dy, canvasHeight - forcedHeight));
      final newDoc = doc.copyWith(dx: newDx, dy: newDy, width: forcedWidth, height: forcedHeight);

      final updatedPage = lastPage.copyWith(documents: [newDoc]);
      state = [...state.sublist(0, lastPageIndex), updatedPage];
      return;
    }

    final lastDoc = lastPage.documents.last;
    double newDx = margin;
    double newDy = margin;

    double potentialDx = lastDoc.dx + lastDoc.width + margin;

    if (potentialDx + forcedWidth <= canvasWidth) {
      newDx = potentialDx;
      newDy = lastDoc.dy;
    } else {
      newDx = margin;
      newDy = lastDoc.dy + lastDoc.height + margin;
    }

    if (newDy + forcedHeight > canvasHeight) {
      // Create new page
      newDx = margin;
      newDy = margin;

      newDx = math.max(0.0, math.min(newDx, canvasWidth - forcedWidth));
      newDy = math.max(0.0, math.min(newDy, canvasHeight - forcedHeight));

      final newDoc = doc.copyWith(dx: newDx, dy: newDy, width: forcedWidth, height: forcedHeight);
      state = [...state, PageModel(documents: [newDoc])];
    } else {
      // Add to last page
      newDx = math.max(0.0, math.min(newDx, canvasWidth - forcedWidth));
      newDy = math.max(0.0, math.min(newDy, canvasHeight - forcedHeight));

      final newDoc = doc.copyWith(dx: newDx, dy: newDy, width: forcedWidth, height: forcedHeight);
      final updatedPage = lastPage.copyWith(documents: [...lastPage.documents, newDoc]);
      state = [...state.sublist(0, lastPageIndex), updatedPage];
    }
  }

  void removeDocumentAt(int pageIndex, int docIndex) {
    if (pageIndex < 0 || pageIndex >= state.length) return;

    final page = state[pageIndex];
    if (docIndex < 0 || docIndex >= page.documents.length) return;

    final updatedDocs = [
      for (int i = 0; i < page.documents.length; i++)
        if (i != docIndex) page.documents[i]
    ];

    if (updatedDocs.isEmpty) {
      // Remove the page if empty, unless it's the only page (maybe keep it empty? Let's remove it)
      state = [
        for (int i = 0; i < state.length; i++)
          if (i != pageIndex) state[i]
      ];
    } else {
      final updatedPage = page.copyWith(documents: updatedDocs);
      state = [
        for (int i = 0; i < state.length; i++)
          if (i == pageIndex) updatedPage else state[i]
      ];
    }
  }

  void updateDocumentAt(int pageIndex, int docIndex, ScannedDocument newDoc) {
    if (pageIndex < 0 || pageIndex >= state.length) return;

    final page = state[pageIndex];
    if (docIndex < 0 || docIndex >= page.documents.length) return;

    final updatedDocs = [
      for (int i = 0; i < page.documents.length; i++)
        if (i == docIndex) newDoc else page.documents[i]
    ];

    final updatedPage = page.copyWith(documents: updatedDocs);
    state = [
      for (int i = 0; i < state.length; i++)
        if (i == pageIndex) updatedPage else state[i]
    ];
  }

  void updateDocumentLayout(int pageIndex, int docIndex, {double? dx, double? dy, double? width, double? height}) {
    if (pageIndex < 0 || pageIndex >= state.length) return;

    final page = state[pageIndex];
    if (docIndex < 0 || docIndex >= page.documents.length) return;

    final doc = page.documents[docIndex];
    final newDoc = doc.copyWith(
      dx: dx,
      dy: dy,
      width: width,
      height: height,
    );
    updateDocumentAt(pageIndex, docIndex, newDoc);
  }

  void clear() {
    state = [];
  }
}

final scannedDocumentsProvider = NotifierProvider<ScannedDocumentsNotifier, List<PageModel>>(() {
  return ScannedDocumentsNotifier();
});

class AppState {
  final WorkMode workMode;
  final bool hasNationalId;
  final bool hasHousingCard;
  final bool hasRationCard;
  final bool hasPassport;
  final DisplayMethod displayMethod;
  final bool addFrame;
  final String fileName;
  final bool smartRecognition;

  AppState({
    this.workMode = WorkMode.single,
    this.hasNationalId = false,
    this.hasHousingCard = false,
    this.hasRationCard = false,
    this.hasPassport = false,
    this.displayMethod = DisplayMethod.onePage,
    this.addFrame = false,
    this.fileName = 'مستمسكاتي',
    this.smartRecognition = false,
  });

  AppState copyWith({
    WorkMode? workMode,
    bool? hasNationalId,
    bool? hasHousingCard,
    bool? hasRationCard,
    bool? hasPassport,
    DisplayMethod? displayMethod,
    bool? addFrame,
    String? fileName,
    bool? smartRecognition,
  }) {
    return AppState(
      workMode: workMode ?? this.workMode,
      hasNationalId: hasNationalId ?? this.hasNationalId,
      hasHousingCard: hasHousingCard ?? this.hasHousingCard,
      hasRationCard: hasRationCard ?? this.hasRationCard,
      hasPassport: hasPassport ?? this.hasPassport,
      displayMethod: displayMethod ?? this.displayMethod,
      addFrame: addFrame ?? this.addFrame,
      fileName: fileName ?? this.fileName,
      smartRecognition: smartRecognition ?? this.smartRecognition,
    );
  }

  bool get hasAtLeastOneDocument =>
      hasNationalId || hasHousingCard || hasRationCard || hasPassport;
}

class AppStateNotifier extends Notifier<AppState> {
  @override
  AppState build() => AppState();

  void updateWorkMode(WorkMode mode) => state = state.copyWith(workMode: mode);

  void toggleNationalId(bool? value) => state = state.copyWith(hasNationalId: value ?? false);
  void toggleHousingCard(bool? value) => state = state.copyWith(hasHousingCard: value ?? false);
  void toggleRationCard(bool? value) => state = state.copyWith(hasRationCard: value ?? false);
  void togglePassport(bool? value) => state = state.copyWith(hasPassport: value ?? false);

  void updateDisplayMethod(DisplayMethod method) => state = state.copyWith(displayMethod: method);

  void toggleAddFrame(bool value) => state = state.copyWith(addFrame: value);

  void updateFileName(String name) => state = state.copyWith(fileName: name);

  void toggleSmartRecognition(bool value) => state = state.copyWith(smartRecognition: value);
}

final appStateProvider = NotifierProvider<AppStateNotifier, AppState>(() {
  return AppStateNotifier();
});
