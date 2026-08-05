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

class ScannedDocumentsNotifier extends Notifier<Map<int, List<ScannedDocument>>> {
  @override
  Map<int, List<ScannedDocument>> build() => {};

  void addDocument(ScannedDocument doc, AppState appState) {
    const double canvasWidth = 380.0;
    const double canvasHeight = 537.32; // 380 * 1.414
    const double margin = 20.0;
    final double pixelPerMm = canvasWidth / 210.0;

    // Apply real-world dimensions based on selected documents
    double targetWidthMm = 85.6; // National ID default
    double targetHeightMm = 54.0;

    int selectedCount = 0;
    if (appState.hasNationalId) selectedCount++;
    if (appState.hasHousingCard) selectedCount++;
    if (appState.hasRationCard) selectedCount++;
    if (appState.hasPassport) selectedCount++;

    if (selectedCount > 1) {
      // Multiple selected -> fallback to National ID size
      targetWidthMm = 85.6;
      targetHeightMm = 54.0;
    } else {
      if (appState.hasRationCard) {
        targetWidthMm = 148.0;
        targetHeightMm = 210.0; // Ration card is portrait
      } else if (appState.hasHousingCard) {
        targetWidthMm = 105.0;
        targetHeightMm = 75.0;
      } else if (appState.hasPassport) {
        targetWidthMm = 176.0;
        targetHeightMm = 125.0;
      } else if (appState.hasNationalId) {
        targetWidthMm = 85.6;
        targetHeightMm = 54.0;
      }
    }

    double forcedWidth = targetWidthMm * pixelPerMm;
    double forcedHeight = targetHeightMm * pixelPerMm;

    // Constrain width and height to canvas limits, just in case
    forcedWidth = math.min(forcedWidth, canvasWidth - margin * 2);
    forcedHeight = math.min(forcedHeight, canvasHeight - margin * 2);

    // Enforce display method limits early
    if (appState.displayMethod == DisplayMethod.frontOnly && state.isNotEmpty && (state[0] ?? []).isNotEmpty) {
      return;
    }

    if (state.isEmpty) {
      double newDx = margin;
      double newDy = margin;

      final newDoc = doc.copyWith(dx: newDx, dy: newDy, width: forcedWidth, height: forcedHeight);
      state = {0: [newDoc]};
      return;
    }

    final lastPageIndex = state.keys.reduce(math.max);
    final lastPageDocs = List<ScannedDocument>.from(state[lastPageIndex] ?? []);

    if (lastPageDocs.isEmpty) {
      double newDx = margin;
      double newDy = margin;
      final newDoc = doc.copyWith(dx: newDx, dy: newDy, width: forcedWidth, height: forcedHeight);

      state = {
        ...state,
        lastPageIndex: [newDoc],
      };
      return;
    }

    // Determine placement logic based on display method
    if (appState.displayMethod == DisplayMethod.twoPages) {
      // Force new page, centered at top
      double newDx = (canvasWidth - forcedWidth) / 2.0;
      double newDy = margin;
      final newDoc = doc.copyWith(dx: newDx, dy: newDy, width: forcedWidth, height: forcedHeight);
      state = {
        ...state,
        lastPageIndex + 1: [newDoc]
      };
      return;
    }

    // Smart wrapping logic for onePage
    double currentDx = margin;
    double currentDy = margin;


    // Re-evaluate positions based on the last document
    final lastDoc = lastPageDocs.last;

    // First try side-by-side
    double potentialDx = lastDoc.dx + lastDoc.width + margin;

    if (potentialDx + forcedWidth <= canvasWidth) {
      // Fits on the right
      currentDx = potentialDx;
      currentDy = lastDoc.dy;
    } else {
      // Need a new row
      currentDx = margin;
      // Find the maximum Y bounds of all documents in the current "row" (rough estimation)
      // For better wrapping, let's just use the lowest point of any document on the page
      double lowestPoint = 0;
      for (var d in lastPageDocs) {
         if (d.dy + d.height > lowestPoint) {
             lowestPoint = d.dy + d.height;
         }
      }
      currentDy = lowestPoint + margin;
    }

    if (currentDy + forcedHeight > canvasHeight) {
      // Create new page
      currentDx = margin;
      currentDy = margin;

      final newDoc = doc.copyWith(dx: currentDx, dy: currentDy, width: forcedWidth, height: forcedHeight);
      state = {
        ...state,
        lastPageIndex + 1: [newDoc]
      };
    } else {
      // Add to last page
      final newDoc = doc.copyWith(dx: currentDx, dy: currentDy, width: forcedWidth, height: forcedHeight);
      state = {
        ...state,
        lastPageIndex: [...lastPageDocs, newDoc]
      };
    }
  }

  void removeDocumentAt(int pageIndex, int docIndex) {
    if (!state.containsKey(pageIndex)) return;

    final pageDocs = state[pageIndex]!;
    if (docIndex < 0 || docIndex >= pageDocs.length) return;

    final updatedDocs = [
      for (int i = 0; i < pageDocs.length; i++)
        if (i != docIndex) pageDocs[i]
    ];

    if (updatedDocs.isEmpty) {
      // Remove the page if empty
      final newState = Map<int, List<ScannedDocument>>.from(state)..remove(pageIndex);
      // Re-index pages so they are contiguous starting from 0
      final reindexedState = <int, List<ScannedDocument>>{};
      int newIdx = 0;
      final sortedKeys = newState.keys.toList()..sort();
      for (var key in sortedKeys) {
        reindexedState[newIdx++] = newState[key]!;
      }
      state = reindexedState;
    } else {
      state = {
        ...state,
        pageIndex: updatedDocs,
      };
    }
  }

  void updateDocumentAt(int pageIndex, int docIndex, ScannedDocument newDoc) {
    if (!state.containsKey(pageIndex)) return;

    final pageDocs = state[pageIndex]!;
    if (docIndex < 0 || docIndex >= pageDocs.length) return;

    final updatedDocs = [
      for (int i = 0; i < pageDocs.length; i++)
        if (i == docIndex) newDoc else pageDocs[i]
    ];

    state = {
      ...state,
      pageIndex: updatedDocs,
    };
  }

  void updateDocumentLayout(int pageIndex, int docIndex, {double? dx, double? dy, double? width, double? height}) {
    if (!state.containsKey(pageIndex)) return;

    final pageDocs = state[pageIndex]!;
    if (docIndex < 0 || docIndex >= pageDocs.length) return;

    final doc = pageDocs[docIndex];
    final newDoc = doc.copyWith(
      dx: dx,
      dy: dy,
      width: width,
      height: height,
    );
    updateDocumentAt(pageIndex, docIndex, newDoc);
  }

  void clear() {
    state = {};
  }
}

final scannedDocumentsProvider = NotifierProvider<ScannedDocumentsNotifier, Map<int, List<ScannedDocument>>>(() {
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
