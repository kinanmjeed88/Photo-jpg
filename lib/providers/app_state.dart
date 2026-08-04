import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum WorkMode { single, family }
enum DisplayMethod { onePage, twoPages, frontOnly }
enum DocumentType { nationalId, housingCard, rationCard, passport, unknown }

class ScannedDocument {
  final File file;
  final DocumentType type;

  ScannedDocument({required this.file, this.type = DocumentType.unknown});
}

class ScannedDocumentsNotifier extends Notifier<List<ScannedDocument>> {
  @override
  List<ScannedDocument> build() => [];

  void addDocument(ScannedDocument doc) {
    state = [...state, doc];
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
  final bool autoDeskew;

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
    this.autoDeskew = false,
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
    bool? autoDeskew,
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
      autoDeskew: autoDeskew ?? this.autoDeskew,
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
  void toggleAutoDeskew(bool value) => state = state.copyWith(autoDeskew: value);
}

final appStateProvider = NotifierProvider<AppStateNotifier, AppState>(() {
  return AppStateNotifier();
});
