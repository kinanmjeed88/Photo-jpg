import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum WorkMode { single, family }
enum DisplayMethod { onePage, twoPages, frontOnly }
enum DocumentType { nationalId, housingCard, rationCard, passport, unknown, a4Document }

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
    const double VIRTUAL_A4_WIDTH = 400.0;
    const double VIRTUAL_A4_HEIGHT = 565.6; // 400 * 1.414
    const double margin = 10.0;

    DocumentType effectiveType = doc.type != DocumentType.unknown
        ? doc.type
        : _guessDocumentType(appState);

    // Keep the actual aspect ratio, but scale if it's too large
    double newDocWidth = doc.width;
    double newDocHeight = doc.height;

    // Default scaling strategy if width is exactly 300 (which is the default from scanner screen)
    if (newDocWidth == 300) {
        if (effectiveType == DocumentType.a4Document) {
          newDocWidth = VIRTUAL_A4_WIDTH;
        } else if (effectiveType == DocumentType.passport) {
          newDocWidth = VIRTUAL_A4_WIDTH * 0.85;
        } else if (effectiveType == DocumentType.rationCard) {
          newDocWidth = VIRTUAL_A4_WIDTH * 0.90;
        } else {
          newDocWidth = VIRTUAL_A4_WIDTH * 0.42; // default for ID cards
        }

        // Maintain the intrinsic aspect ratio
        double aspect = doc.width / doc.height;
        newDocHeight = newDocWidth / aspect;
    }

    if (effectiveType == DocumentType.a4Document) {
        // Enforce full canvas for A4
        newDocWidth = VIRTUAL_A4_WIDTH;
        newDocHeight = VIRTUAL_A4_HEIGHT;
    }

    // Clamp dimensions to canvas limits to prevent overflow
    if (newDocWidth > VIRTUAL_A4_WIDTH) {
        double aspect = newDocWidth / newDocHeight;
        newDocWidth = VIRTUAL_A4_WIDTH;
        newDocHeight = newDocWidth / aspect;
    }
    if (newDocHeight > VIRTUAL_A4_HEIGHT) {
        double aspect = newDocWidth / newDocHeight;
        newDocHeight = VIRTUAL_A4_HEIGHT;
        newDocWidth = newDocHeight * aspect;
    }

    if (appState.displayMethod == DisplayMethod.frontOnly && state.isNotEmpty && (state[0] ?? []).isNotEmpty) {
      return;
    }

    ScannedDocument newDoc = doc.copyWith(
      type: effectiveType,
      width: newDocWidth,
      height: newDocHeight,
    );

    if (state.isEmpty) {
      state = {0: [newDoc.copyWith(dx: margin, dy: margin)]};
      return;
    }

    int pageIndex = state.keys.reduce(math.max);
    List<ScannedDocument> pageDocs = List<ScannedDocument>.from(state[pageIndex] ?? []);

    if (appState.displayMethod == DisplayMethod.twoPages && pageDocs.isNotEmpty) {
      pageIndex++;
      state = {
        ...state,
        pageIndex: [newDoc.copyWith(dx: margin, dy: margin)]
      };
      return;
    }

    if (pageDocs.isEmpty) {
      state = {
        ...state,
        pageIndex: [newDoc.copyWith(dx: effectiveType == DocumentType.a4Document ? 0 : margin, dy: effectiveType == DocumentType.a4Document ? 0 : margin)],
      };
      return;
    }

    if (effectiveType == DocumentType.a4Document) {
      pageIndex++;
      state = {
        ...state,
        pageIndex: [newDoc.copyWith(dx: 0, dy: 0)],
      };
      return;
    }

    // Calculate layout dynamically based on actual sizes
    double currentDx = margin;
    double currentDy = margin;

    // Find bottom-most item to place below it, or right-most item to place next to it
    if (pageDocs.length == 1) {
       currentDx = margin + pageDocs[0].width + margin;
       currentDy = margin;
       if (currentDx + newDocWidth > VIRTUAL_A4_WIDTH) {
           currentDx = margin;
           currentDy = margin + pageDocs[0].height + margin;
       }
    } else if (pageDocs.length == 2) {
       currentDx = margin;
       currentDy = margin + math.max(pageDocs[0].height, pageDocs[1].height) + margin;
    } else if (pageDocs.length == 3) {
       currentDx = margin + pageDocs[2].width + margin;
       currentDy = pageDocs[2].dy;
       if (currentDx + newDocWidth > VIRTUAL_A4_WIDTH) {
           currentDx = margin;
           currentDy = pageDocs[2].dy + pageDocs[2].height + margin;
       }
    }

    // If it still overflows height or max 4 items, new page
    if (pageDocs.length >= 4 || currentDy + newDocHeight > VIRTUAL_A4_HEIGHT) {
      pageIndex++;
      pageDocs = [];
      currentDx = margin;
      currentDy = margin;
    }

    state = {
      ...state,
      pageIndex: [...pageDocs, newDoc.copyWith(dx: currentDx, dy: currentDy)]
    };
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


  void moveDocumentToTop(int pageIndex, int docIndex) {
    if (!state.containsKey(pageIndex)) return;
    final pageDocs = List<ScannedDocument>.from(state[pageIndex]!);
    if (docIndex < 0 || docIndex >= pageDocs.length) return;

    final doc = pageDocs.removeAt(docIndex);
    pageDocs.add(doc);

    state = {
      ...state,
      pageIndex: pageDocs,
    };
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
