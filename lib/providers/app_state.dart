import 'dart:io';
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
  final int pageIndex;

  ScannedDocument({
    required this.file,
    this.type = DocumentType.unknown,
    this.dx = 20,
    this.dy = 20,
    this.width = 300,
    this.height = 400,
    this.pageIndex = 0,
  });

  ScannedDocument copyWith({
    File? file,
    DocumentType? type,
    double? dx,
    double? dy,
    double? width,
    double? height,
    int? pageIndex,
  }) {
    return ScannedDocument(
      file: file ?? this.file,
      type: type ?? this.type,
      dx: dx ?? this.dx,
      dy: dy ?? this.dy,
      width: width ?? this.width,
      height: height ?? this.height,
      pageIndex: pageIndex ?? this.pageIndex,
    );
  }
}

class ScannedDocumentsNotifier extends Notifier<List<ScannedDocument>> {
  @override
  List<ScannedDocument> build() => [];

  void addDocument(ScannedDocument doc) {
    // Basic automatic placement for new documents
    int newPageIndex = 0;
    double newDx = 20.0;
    double newDy = 20.0;
    if (state.isNotEmpty) {
      final lastDoc = state.last;
      newPageIndex = lastDoc.pageIndex;

      // Try to place horizontally next to the last document
      double potentialDx = lastDoc.dx + lastDoc.width + 20.0;

      // Assuming a standard A4 canvas UI width is roughly around 350-400 max
      if (potentialDx + doc.width < 380) {
        newDx = potentialDx;
        newDy = lastDoc.dy; // Stay on same row
      } else {
        // Wrap to new row
        newDx = 20.0;
        newDy = lastDoc.dy + lastDoc.height + 20.0;

        // If it exceeds a reasonable A4 height estimate in UI, move to next page
        if (newDy > 600) {
          newPageIndex++;
          newDy = 20.0;
        }
      }
    } else {
      // First document uses the default properties in doc, but force safe padding if zero
      newDx = doc.dx;
      newDy = doc.dy;
    }

    final newDoc = doc.copyWith(pageIndex: newPageIndex, dx: newDx, dy: newDy);
    state = [...state, newDoc];
  }

  void removeDocumentAt(int index) {
    state = [
      for (int i = 0; i < state.length; i++)
        if (i != index) state[i]
    ];
  }

  void updateDocumentAt(int index, ScannedDocument newDoc) {
    state = [
      for (int i = 0; i < state.length; i++)
        if (i == index) newDoc else state[i]
    ];
  }

  void updateDocumentLayout(int index, {double? dx, double? dy, double? width, double? height, int? pageIndex}) {
    if (index >= 0 && index < state.length) {
      final doc = state[index];
      final newDoc = doc.copyWith(
        dx: dx,
        dy: dy,
        width: width,
        height: height,
        pageIndex: pageIndex,
      );
      updateDocumentAt(index, newDoc);
    }
  }

  void clear() {
    state = [];
  }
}

final scannedDocumentsProvider = NotifierProvider<ScannedDocumentsNotifier, List<ScannedDocument>>(() {
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
