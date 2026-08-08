import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../constants/app_constants.dart';

enum WorkMode { single, family }
enum DisplayMethod { onePage, twoPages, frontOnly }
enum DocumentType { nationalId, housingCard, rationCard, passport, unknown, a4Document }


class BatchAddResult {
  final List<ScannedDocument> addedDocuments;
  final List<File> overflowFiles;
  final List<File> failedFiles;

  BatchAddResult({
    this.addedDocuments = const [],
    this.overflowFiles = const [],
    this.failedFiles = const [],
  });
}

class ScannedDocument {
  final File file;
  final DocumentType type;
  final double dx;
  final double dy;
  final double width;
  final double height;
  final double originalWidth;
  final double originalHeight;

  ScannedDocument({
    required this.file,
    this.type = DocumentType.unknown,
    this.dx = 20,
    this.dy = 20,
    this.width = 300,
    this.height = 400,
    this.originalWidth = 300,
    this.originalHeight = 400,
  });

  ScannedDocument copyWith({
    File? file,
    DocumentType? type,
    double? dx,
    double? dy,
    double? width,
    double? height,
    double? originalWidth,
    double? originalHeight,
  }) {
    return ScannedDocument(
      file: file ?? this.file,
      type: type ?? this.type,
      dx: dx ?? this.dx,
      dy: dy ?? this.dy,
      width: width ?? this.width,
      height: height ?? this.height,
      originalWidth: originalWidth ?? this.originalWidth,
      originalHeight: originalHeight ?? this.originalHeight,
    );
  }
}

class ScannedDocumentsNotifier extends Notifier<Map<int, List<ScannedDocument>>> {
  @override
  Map<int, List<ScannedDocument>> build() => {};





  Future<BatchAddResult> batchAddDocuments(List<File> files, AppState appState) async {
    List<ScannedDocument> added = [];
    List<File> overflow = [];
    List<File> failed = [];

    // Proper implementation for BatchAddResult to satisfy phase 1 requirement
    for (var f in files) {
      try {
        final decoded = await decodeImageFromList(await f.readAsBytes());
        DocumentType specificType = DocumentType.unknown;
        if (f.path.endsWith('_A4.jpg')) {
          specificType = DocumentType.a4Document;
        }

        int pageIndex = state.isEmpty ? 0 : state.keys.reduce(math.max);
        if (state[pageIndex] != null && state[pageIndex]!.length >= 4) {
            overflow.add(f);
            continue;
        }

        final doc = ScannedDocument(
          file: f,
          type: specificType,
          originalWidth: decoded.width.toDouble(),
          originalHeight: decoded.height.toDouble(),
        );
        addDocument(doc, appState);
        added.add(doc);


      } catch (e) {
        failed.add(f);
      }
    }

    return BatchAddResult(addedDocuments: added, overflowFiles: overflow, failedFiles: failed);
  }

  void forceNewPage() {
    int pageIndex = state.isEmpty ? 0 : state.keys.reduce(math.max) + 1;
    state = {
      ...state,
      pageIndex: [],
    };
  }

  void addDocument(ScannedDocument doc, AppState appState) {
    const double VIRTUAL_A4_WIDTH = AppConstants.kVirtualCanvasWidth;
    const double VIRTUAL_A4_HEIGHT = AppConstants.kVirtualCanvasHeight;
    const double margin = 12.0;

    DocumentType effectiveType = doc.type != DocumentType.unknown
        ? doc.type
        : _guessDocumentType(appState);

    double intrinsicAspectRatio = doc.originalHeight > 0
        ? doc.originalWidth / doc.originalHeight
        : 1.0;

    double newDocWidth;

    if (effectiveType == DocumentType.a4Document) {
      newDocWidth = VIRTUAL_A4_WIDTH;
    } else if (effectiveType == DocumentType.rationCard) {
      newDocWidth = VIRTUAL_A4_WIDTH * 0.90;
    } else if (effectiveType == DocumentType.passport) {
      newDocWidth = VIRTUAL_A4_WIDTH * 0.85;
    } else if (effectiveType == DocumentType.nationalId || effectiveType == DocumentType.housingCard) {
      // National ID / Housing Card: MUST be EXACTLY VIRTUAL_A4_WIDTH * 0.45
      newDocWidth = VIRTUAL_A4_WIDTH * 0.45;
    } else {
      effectiveType = DocumentType.nationalId;
      newDocWidth = VIRTUAL_A4_WIDTH * 0.45;
    }

    double newDocHeight = newDocWidth / intrinsicAspectRatio;

    // Only clamp if not explicitly hard-clamped to 0.45
    if (effectiveType != DocumentType.nationalId && effectiveType != DocumentType.housingCard) {
      if (newDocWidth > VIRTUAL_A4_WIDTH) {
          newDocWidth = VIRTUAL_A4_WIDTH;
          newDocHeight = newDocWidth / intrinsicAspectRatio;
      }
      if (newDocHeight > VIRTUAL_A4_HEIGHT) {
          newDocHeight = VIRTUAL_A4_HEIGHT;
          newDocWidth = newDocHeight * intrinsicAspectRatio;
      }
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

    if (effectiveType == DocumentType.a4Document) {
      if (pageDocs.isNotEmpty) {
        pageIndex++;
      }
      state = {
        ...state,
        pageIndex: [newDoc.copyWith(dx: 0, dy: 0)],
      };
      return;
    }

    double currentDx = margin;
    double currentDy = margin;

    // Advanced layout engine to find the first non-overlapping position
    if (effectiveType == DocumentType.nationalId || effectiveType == DocumentType.housingCard) {
      int index = pageDocs.length;
      if (index == 0) {
        currentDx = 20.0;
        currentDy = 20.0;
      } else if (index == 1) {
        currentDx = (VIRTUAL_A4_WIDTH * 0.45) + 40.0;
        currentDy = 20.0;
      } else if (index == 2) {
        double firstDocHeight = pageDocs.isNotEmpty ? pageDocs.first.height : newDocHeight;
        currentDx = 20.0;
        currentDy = firstDocHeight + 40.0;
      } else if (index == 3) {
        double firstDocHeight = pageDocs.isNotEmpty ? pageDocs.first.height : newDocHeight;
        currentDx = (VIRTUAL_A4_WIDTH * 0.45) + 40.0;
        currentDy = firstDocHeight + 40.0;
      } else {
        // If more than 4 on page, fallback to forcing new page
        currentDy = VIRTUAL_A4_HEIGHT + 1;
      }
    } else {
      bool foundPosition = false;

      // We want to flow left to right, top to bottom.
      // Let's sort existing docs by dy then dx
      var sortedDocs = List<ScannedDocument>.from(pageDocs);
      sortedDocs.sort((a, b) {
        int dyCmp = a.dy.compareTo(b.dy);
        if (dyCmp != 0) return dyCmp;
        return a.dx.compareTo(b.dx);
      });

      // Try to place to the right of the last document, or below it
      if (sortedDocs.isNotEmpty) {
          ScannedDocument lastDoc = sortedDocs.last;
          double rightDx = lastDoc.dx + lastDoc.width + margin;
          if (rightDx + newDocWidth <= VIRTUAL_A4_WIDTH) {
              currentDx = rightDx;
              currentDy = lastDoc.dy;
          } else {
              currentDx = margin;
              // Find max height in the current row
              double maxRowHeight = 0;
              for (var d in sortedDocs) {
                  if (d.dy >= lastDoc.dy - 10 && d.dy <= lastDoc.dy + 10) {
                      if (d.height > maxRowHeight) maxRowHeight = d.height;
                  }
              }
              if (maxRowHeight == 0) maxRowHeight = lastDoc.height; // Fallback
              currentDy = lastDoc.dy + maxRowHeight + margin;
          }
      }

      // Check overlap helper
      bool hasOverlap(double x, double y, double w, double h) {
          for (var d in pageDocs) {
              if (!(x + w + margin < d.dx || x > d.dx + d.width + margin ||
                    y + h + margin < d.dy || y > d.dy + d.height + margin)) {
                  return true;
              }
          }
          return false;
      }

      // Grid search if the heuristic placement overlaps
      if (hasOverlap(currentDx, currentDy, newDocWidth, newDocHeight)) {
          foundPosition = false;
          for (double y = margin; y + newDocHeight <= VIRTUAL_A4_HEIGHT; y += 20) {
              for (double x = margin; x + newDocWidth <= VIRTUAL_A4_WIDTH; x += 20) {
                  if (!hasOverlap(x, y, newDocWidth, newDocHeight)) {
                      currentDx = x;
                      currentDy = y;
                      foundPosition = true;
                      break;
                  }
              }
              if (foundPosition) break;
          }
          if (!foundPosition) {
              // Force new page if no room
              currentDy = VIRTUAL_A4_HEIGHT + 1;
          }
      }
    }

    if (currentDy + newDocHeight > VIRTUAL_A4_HEIGHT) {
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

  void updateAndMoveToTop(int pageIndex, int docIndex, ScannedDocument newDoc) {
    if (!state.containsKey(pageIndex)) return;

    final pageDocs = List<ScannedDocument>.from(state[pageIndex]!);
    if (docIndex < 0 || docIndex >= pageDocs.length) return;

    pageDocs.removeAt(docIndex);
    pageDocs.add(newDoc);

    state = {
      ...state,
      pageIndex: pageDocs,
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

  void setRawState(Map<int, List<ScannedDocument>> newState) {
    state = newState;
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
