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
    final double scaleFactor = (canvasWidth * 0.45) / 85.6;

    // Determine type from doc.type if known, else from appState
    DocumentType effectiveType = doc.type != DocumentType.unknown
        ? doc.type
        : _guessDocumentType(appState);

    double newDocWidth = 0.0;
    double newDocHeight = 0.0;

    switch (effectiveType) {
      case DocumentType.nationalId:
        newDocWidth = 85.6 * scaleFactor;
        newDocHeight = 54.0 * scaleFactor;
        break;
      case DocumentType.passport:
        newDocWidth = 176.0 * scaleFactor;
        newDocHeight = 125.0 * scaleFactor;
        break;
      case DocumentType.rationCard:
        newDocWidth = 210.0 * scaleFactor;
        newDocHeight = 148.0 * scaleFactor;
        break;
      case DocumentType.housingCard:
        newDocWidth = 105.0 * scaleFactor;
        newDocHeight = 75.0 * scaleFactor;
        break;
      default:
        newDocWidth = 85.6 * scaleFactor;
        newDocHeight = 54.0 * scaleFactor;
    }

    // Constrain width and height to canvas limits
    newDocWidth = math.min(newDocWidth, canvasWidth - margin * 2);
    newDocHeight = math.min(newDocHeight, canvasHeight - margin * 2);

    // Enforce display method limits early
    if (appState.displayMethod == DisplayMethod.frontOnly && state.isNotEmpty && (state[0] ?? []).isNotEmpty) {
      return;
    }

    if (state.isEmpty) {
      state = {0: [doc.copyWith(dx: margin, dy: margin, width: newDocWidth, height: newDocHeight)]};
      return;
    }

    int pageIndex = state.keys.reduce(math.max);
    List<ScannedDocument> pageDocs = List<ScannedDocument>.from(state[pageIndex] ?? []);

    if (appState.displayMethod == DisplayMethod.twoPages && pageDocs.isNotEmpty) {
      pageIndex++;
      state = {
        ...state,
        pageIndex: [doc.copyWith(dx: margin, dy: margin, width: newDocWidth, height: newDocHeight)]
      };
      return;
    }

    if (pageDocs.isEmpty) {
      state = {
        ...state,
        pageIndex: [doc.copyWith(dx: margin, dy: margin, width: newDocWidth, height: newDocHeight)],
      };
      return;
    }

    double currentDx = margin;
    double currentDy = margin;
    double currentRowMaxHeight = 0;

    // Calculate layout up to the current documents to find insertion point
    for (var existingDoc in pageDocs) {
      if (currentDx + existingDoc.width + margin > canvasWidth) {
        currentDx = margin;
        currentDy += currentRowMaxHeight + margin;
        currentRowMaxHeight = 0;
      }
      currentDx += existingDoc.width + margin;
      if (existingDoc.height > currentRowMaxHeight) {
        currentRowMaxHeight = existingDoc.height;
      }
    }

    // Check wrapping for new document
    if (currentDx + newDocWidth + margin > canvasWidth) {
      currentDx = margin;
      currentDy += currentRowMaxHeight + margin;
      currentRowMaxHeight = 0;
    }

    // Check strict page break
    if (currentDy + newDocHeight + margin > canvasHeight) {
      pageIndex++;
      currentDx = margin;
      currentDy = margin;

      state = {
        ...state,
        pageIndex: [doc.copyWith(dx: currentDx, dy: currentDy, width: newDocWidth, height: newDocHeight)]
      };
    } else {
      state = {
        ...state,
        pageIndex: [...pageDocs, doc.copyWith(dx: currentDx, dy: currentDy, width: newDocWidth, height: newDocHeight)]
      };
    }
  }

  DocumentType _guessDocumentType(AppState appState) {
    if (appState.hasRationCard) return DocumentType.rationCard;
    if (appState.hasPassport) return DocumentType.passport;
    if (appState.hasHousingCard) return DocumentType.housingCard;
    return DocumentType.nationalId;
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
