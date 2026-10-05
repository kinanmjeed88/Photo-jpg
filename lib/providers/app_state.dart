import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/app_constants.dart';
import '../services/app_settings_store.dart';
import '../services/image_pipeline.dart';

enum DisplayMethod { onePage, twoPages, frontOnly }

enum DocumentType {
  /// Smart-scan selection mode: detect all unified cards in the source image.
  allDocuments,
  nationalId,
  housingCard,
  rationCard,
  passport,
  unknown,
  a4Document,
}

@immutable
class DocumentInput {
  const DocumentInput({
    required this.file,
    this.type = DocumentType.unknown,
    this.originalImagePath,
  });

  final File file;
  final DocumentType type;
  final String? originalImagePath;
}

@immutable
class BatchAddResult {
  const BatchAddResult({
    this.addedDocuments = const <ScannedDocument>[],
    this.overflowInputs = const <DocumentInput>[],
    this.overflowFiles = const <File>[],
    this.failedFiles = const <File>[],
    this.skippedFiles = const <File>[],
  });

  final List<ScannedDocument> addedDocuments;

  /// Inputs that did not fit on the current page, kept as full [DocumentInput]
  /// values so a follow-up placement on a new page preserves the detected type
  /// and the original source path instead of falling back to a guessed type.
  final List<DocumentInput> overflowInputs;

  /// Convenience projection of [overflowInputs] used by the UI for messaging.
  final List<File> overflowFiles;
  final List<File> failedFiles;
  final List<File> skippedFiles;
}

@immutable
class DocumentLocation {
  const DocumentLocation({required this.pageIndex, required this.document});

  final int pageIndex;
  final ScannedDocument document;
}

@immutable
class ScannedDocument {
  factory ScannedDocument({
    required File file,
    DocumentType type = DocumentType.unknown,
    double dx = 20,
    double dy = 20,
    double width = 300,
    double height = 400,
    double originalWidth = 300,
    double originalHeight = 400,
    int rotationAngle = 0,
    String? originalImagePath,
    double scale = 1.0,
    String? id,
  }) {
    return ScannedDocument._(
      id: id ?? _DocumentIdGenerator.next(),
      file: file,
      type: type,
      dx: dx,
      dy: dy,
      width: width,
      height: height,
      originalWidth: originalWidth,
      originalHeight: originalHeight,
      rotationAngle: rotationAngle,
      originalImagePath: originalImagePath,
      scale: scale,
    );
  }

  const ScannedDocument._({
    required this.id,
    required this.file,
    required this.type,
    required this.dx,
    required this.dy,
    required this.width,
    required this.height,
    required this.originalWidth,
    required this.originalHeight,
    required this.rotationAngle,
    required this.originalImagePath,
    required this.scale,
  });

  final String id;
  final File file;
  final DocumentType type;
  final double dx;
  final double dy;
  final double width;
  final double height;
  final double originalWidth;
  final double originalHeight;
  final int rotationAngle;
  final String? originalImagePath;
  final double scale;

  Offset get position => Offset(dx, dy);

  ScannedDocument copyWith({
    File? file,
    DocumentType? type,
    double? dx,
    double? dy,
    double? width,
    double? height,
    double? originalWidth,
    double? originalHeight,
    int? rotationAngle,
    String? originalImagePath,
    double? scale,
  }) {
    return ScannedDocument._(
      id: id,
      file: file ?? this.file,
      type: type ?? this.type,
      dx: dx ?? this.dx,
      dy: dy ?? this.dy,
      width: width ?? this.width,
      height: height ?? this.height,
      originalWidth: originalWidth ?? this.originalWidth,
      originalHeight: originalHeight ?? this.originalHeight,
      rotationAngle: rotationAngle ?? this.rotationAngle,
      originalImagePath: originalImagePath ?? this.originalImagePath,
      scale: scale ?? this.scale,
    );
  }
}

class _DocumentIdGenerator {
  static final math.Random _random = math.Random.secure();

  static String next() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }
}

class ScannedDocumentsNotifier
    extends Notifier<Map<int, List<ScannedDocument>>> {
  static const double _margin = 12;
  static const int _maxDocumentsPerPage = 4;

  @override
  Map<int, List<ScannedDocument>> build() =>
      _freeze(<int, List<ScannedDocument>>{});

  /// The sole intake API. Camera, gallery, smart-crop and manual-crop flows all
  /// use this method so that [DisplayMethod] is enforced consistently.
  Future<BatchAddResult> placeDocuments(
    List<DocumentInput> inputs,
    AppState appState,
  ) async {
    final working = _copyState(state);
    final added = <ScannedDocument>[];
    final overflow = <DocumentInput>[];
    final failed = <File>[];
    final skipped = <File>[];

    if (appState.displayMethod == DisplayMethod.frontOnly &&
        _hasAnyDocument(working)) {
      return BatchAddResult(
        skippedFiles: inputs.map((input) => input.file).toList(),
      );
    }

    for (final input in inputs) {
      if (appState.displayMethod == DisplayMethod.frontOnly &&
          added.isNotEmpty) {
        skipped.add(input.file);
        continue;
      }

      try {
        final dimensions = await _readImageDimensions(input.file);
        if (dimensions == null) {
          failed.add(input.file);
          continue;
        }

        final requestedType = input.type == DocumentType.unknown
            ? _guessDocumentType(appState)
            : input.type;
        final document = _newDocument(
          input: input,
          type: requestedType,
          displayMethod: appState.displayMethod,
          originalWidth: dimensions.$1,
          originalHeight: dimensions.$2,
        );
        final outcome = _placeDocument(
          pages: working,
          document: document,
          displayMethod: appState.displayMethod,
        );

        if (outcome == _PlacementOutcome.added) {
          added.add(document);
        } else {
          overflow.add(input);
        }
      } catch (_) {
        failed.add(input.file);
      }
    }

    state = _freeze(working);
    return BatchAddResult(
      addedDocuments: List.unmodifiable(added),
      overflowInputs: List.unmodifiable(overflow),
      overflowFiles: List.unmodifiable(overflow.map((input) => input.file)),
      failedFiles: List.unmodifiable(failed),
      skippedFiles: List.unmodifiable(skipped),
    );
  }

  int forceNewPage() {
    final nextPage = _nextPageIndex(state);
    final working = _copyState(state)
      ..putIfAbsent(nextPage, () => <ScannedDocument>[]);
    state = _freeze(working);
    return nextPage;
  }

  DocumentLocation? findDocument(String documentId) {
    for (final entry in state.entries) {
      for (final document in entry.value) {
        if (document.id == documentId) {
          return DocumentLocation(pageIndex: entry.key, document: document);
        }
      }
    }
    return null;
  }

  ScannedDocument? removeDocument(String documentId) {
    final location = findDocument(documentId);
    if (location == null) return null;

    final working = _copyState(state);
    final page = List<ScannedDocument>.from(working[location.pageIndex]!);
    page.removeWhere((document) => document.id == documentId);
    if (page.isEmpty && location.pageIndex != 0) {
      working.remove(location.pageIndex);
    } else {
      working[location.pageIndex] = page;
    }
    state = _freeze(working);
    return location.document;
  }

  void updateDocument(
    String documentId, {
    File? file,
    DocumentType? type,
    double? dx,
    double? dy,
    double? width,
    double? height,
    double? originalWidth,
    double? originalHeight,
    int? rotationAngle,
    double? scale,
  }) {
    final location = findDocument(documentId);
    if (location == null) return;

    final working = _copyState(state);
    final page = List<ScannedDocument>.from(working[location.pageIndex]!);
    final index = page.indexWhere((document) => document.id == documentId);
    if (index < 0) return;

    page[index] = page[index].copyWith(
      file: file,
      type: type,
      dx: dx,
      dy: dy,
      width: width,
      height: height,
      originalWidth: originalWidth,
      originalHeight: originalHeight,
      rotationAngle: rotationAngle,
      scale: scale,
    );
    working[location.pageIndex] = page;
    state = _freeze(working);
  }

  void updateDocumentLayout(
    String documentId, {
    required double dx,
    required double dy,
    required double width,
    required double height,
    required int rotationAngle,
    double? scale,
  }) {
    updateDocument(
      documentId,
      dx: dx,
      dy: dy,
      width: width,
      height: height,
      rotationAngle: rotationAngle,
      scale: scale,
    );
  }

  /// Swaps the image behind an existing document and re-fits its layout box.
  ///
  /// A crop or an edit changes the pixel dimensions, so the box has to follow
  /// the new aspect ratio: the canvas draws the frame around the *box*, so
  /// keeping an outdated box would letterbox the image inside a frame that no
  /// longer matches it (and the PDF would place that oversized box too).
  ///
  /// The refit is area preserving and keeps the document's centre, so a
  /// document the user scaled or placed by hand stays where it was; the result
  /// is always inside the A4 guide. [rotationAngle] is respected, because a
  /// quarter turn swaps the box's width and height.
  void replaceDocumentImage(
    String documentId, {
    required File file,
    required double originalWidth,
    required double originalHeight,
  }) {
    final location = findDocument(documentId);
    if (location == null) return;
    final document = location.document;

    final safeWidth = originalWidth > 0 ? originalWidth : 1.0;
    final safeHeight = originalHeight > 0 ? originalHeight : 1.0;
    final naturalAspect = safeWidth / safeHeight;
    final rotated = document.rotationAngle % 180 != 0;
    final aspect = rotated ? 1 / naturalAspect : naturalAspect;

    final isA4 = document.type == DocumentType.a4Document;
    final displayedWidth = document.width * document.scale;
    final displayedHeight = document.height * document.scale;
    final displayedArea = displayedWidth * displayedHeight;

    final maxFit = _fitSize(
      aspectRatio: aspect,
      maxWidth: isA4 ? AppConstants.kA4GuideWidth : _gridCellWidth,
      maxHeight: isA4 ? AppConstants.kA4GuideHeight : _gridCellHeight,
    );
    final maxArea = maxFit.$1 * maxFit.$2;
    final factor = (maxArea <= 0 || displayedArea <= 0)
        ? 1.0
        : math.sqrt(displayedArea / maxArea).clamp(0.15, 1.0).toDouble();
    final targetWidth = maxFit.$1 * factor;
    final targetHeight = maxFit.$2 * factor;

    final centerX = document.dx + (displayedWidth / 2);
    final centerY = document.dy + (displayedHeight / 2);

    final updated = document.copyWith(
      file: file,
      originalWidth: safeWidth,
      originalHeight: safeHeight,
      dx: AppConstants.clampToGuideX(centerX - (targetWidth / 2), targetWidth),
      dy: AppConstants.clampToGuideY(
        centerY - (targetHeight / 2),
        targetHeight,
      ),
      width: targetWidth,
      height: targetHeight,
      rotationAngle: document.rotationAngle,
      scale: 1,
    );

    // One state write: the canvas never renders the new box with the old image.
    final working = _copyState(state);
    final page = working[location.pageIndex];
    if (page == null) return;
    final index = page.indexWhere((candidate) => candidate.id == documentId);
    if (index < 0) return;
    page[index] = updated;
    state = _freeze(working);
  }

  void moveDocumentToTop(String documentId) {
    final location = findDocument(documentId);
    if (location == null) return;

    final working = _copyState(state);
    final page = List<ScannedDocument>.from(working[location.pageIndex]!);
    final index = page.indexWhere((document) => document.id == documentId);
    if (index < 0) return;
    final document = page.removeAt(index);
    page.add(document);
    working[location.pageIndex] = page;
    state = _freeze(working);
  }

  /// Performs source removal, target insertion and final layout in one state
  /// transaction. Page keys remain stable for the lifetime of the session.
  void moveDocument(
    String documentId, {
    required int targetPageIndex,
    required double dx,
    required double dy,
  }) {
    final location = findDocument(documentId);
    if (location == null) return;

    final working = _copyState(state);
    final source = List<ScannedDocument>.from(working[location.pageIndex]!);
    final sourceIndex = source.indexWhere(
      (document) => document.id == documentId,
    );
    if (sourceIndex < 0) return;

    final moved = source.removeAt(sourceIndex).copyWith(dx: dx, dy: dy);
    if (source.isEmpty && location.pageIndex != 0) {
      working.remove(location.pageIndex);
    } else {
      working[location.pageIndex] = source;
    }

    final target = List<ScannedDocument>.from(
      working[targetPageIndex] ?? const [],
    );
    target.removeWhere((document) => document.id == documentId);
    target.add(moved);
    working[targetPageIndex] = target;
    state = _freeze(working);
  }

  void clear() => state = _freeze(<int, List<ScannedDocument>>{});

  _PlacementOutcome _placeDocument({
    required Map<int, List<ScannedDocument>> pages,
    required ScannedDocument document,
    required DisplayMethod displayMethod,
  }) {
    var pageIndex = _currentPageIndex(pages);
    final currentPage = pages.putIfAbsent(pageIndex, () => <ScannedDocument>[]);

    if (displayMethod == DisplayMethod.frontOnly) {
      if (_hasAnyDocument(pages)) return _PlacementOutcome.overflow;
      pages[0] = <ScannedDocument>[_centerOnPage(document)];
      return _PlacementOutcome.added;
    }

    if (document.type == DocumentType.a4Document) {
      if (currentPage.isNotEmpty) pageIndex = _nextPageIndex(pages);
      pages[pageIndex] = <ScannedDocument>[_centerOnPage(document)];
      return _PlacementOutcome.added;
    }

    if (displayMethod == DisplayMethod.twoPages && currentPage.isNotEmpty) {
      pageIndex = _nextPageIndex(pages);
      pages[pageIndex] = <ScannedDocument>[_centerOnPage(document)];
      return _PlacementOutcome.added;
    }

    if (currentPage.length >= _maxDocumentsPerPage) {
      return _PlacementOutcome.overflow;
    }

    final positioned = _positionInOnePageGrid(document, currentPage.length);
    currentPage.add(positioned);
    return _PlacementOutcome.added;
  }

  ScannedDocument _newDocument({
    required DocumentInput input,
    required DocumentType type,
    required DisplayMethod displayMethod,
    required double originalWidth,
    required double originalHeight,
  }) {
    final aspectRatio = originalHeight > 0
        ? originalWidth / originalHeight
        : 1.0;
    final isGridLayout =
        displayMethod == DisplayMethod.onePage &&
        type != DocumentType.a4Document;
    final size = isGridLayout
        ? _fitSize(
            aspectRatio: aspectRatio,
            maxWidth: _gridCellWidth,
            maxHeight: _gridCellHeight,
          )
        : _fitSize(
            aspectRatio: aspectRatio,
            maxWidth: AppConstants.kA4GuideWidth,
            maxHeight: AppConstants.kA4GuideHeight,
          );
    return ScannedDocument(
      file: input.file,
      type: type,
      width: size.$1,
      height: size.$2,
      originalWidth: originalWidth,
      originalHeight: originalHeight,
      originalImagePath: input.originalImagePath ?? input.file.path,
    );
  }

  double get _gridCellWidth => (AppConstants.kA4GuideWidth - _margin) / 2;

  double get _gridCellHeight => (AppConstants.kA4GuideHeight - _margin) / 2;

  (double, double) _fitSize({
    required double aspectRatio,
    required double maxWidth,
    required double maxHeight,
  }) {
    final safeAspectRatio = aspectRatio.isFinite && aspectRatio > 0
        ? aspectRatio
        : 1.0;
    var width = maxWidth;
    var height = width / safeAspectRatio;
    if (height > maxHeight) {
      height = maxHeight;
      width = height * safeAspectRatio;
    }
    return (width, height);
  }

  ScannedDocument _centerOnPage(ScannedDocument document) {
    return document.copyWith(
      dx:
          AppConstants.kA4GuideLeft +
          ((AppConstants.kA4GuideWidth - document.width) / 2),
      dy:
          AppConstants.kA4GuideTop +
          ((AppConstants.kA4GuideHeight - document.height) / 2),
    );
  }

  ScannedDocument _positionInOnePageGrid(
    ScannedDocument document,
    int slotIndex,
  ) {
    final column = slotIndex % 2;
    final row = slotIndex ~/ 2;
    final cellLeft =
        AppConstants.kA4GuideLeft + (column * (_gridCellWidth + _margin));
    final cellTop =
        AppConstants.kA4GuideTop + (row * (_gridCellHeight + _margin));
    return document.copyWith(
      dx: cellLeft + ((_gridCellWidth - document.width) / 2),
      dy: cellTop + ((_gridCellHeight - document.height) / 2),
    );
  }

  DocumentType _guessDocumentType(AppState appState) =>
      appState.selectedDocumentType;

  @visibleForTesting
  void seedDocuments(Map<int, List<ScannedDocument>> documents) {
    state = _freeze(_copyState(documents));
  }

  /// Reads the *displayed* pixel dimensions of [file].
  ///
  /// Decoding a full-resolution photo on the UI isolate is what made adding a
  /// batch of images stutter, so the work happens in a background isolate and
  /// EXIF orientation is baked in first: an un-oriented measurement would give
  /// every rotated photo the wrong aspect box.
  Future<(double, double)?> _readImageDimensions(File file) =>
      readOrientedDimensions(file);

  bool _hasAnyDocument(Map<int, List<ScannedDocument>> pages) {
    return pages.values.any((documents) => documents.isNotEmpty);
  }

  int _currentPageIndex(Map<int, List<ScannedDocument>> pages) {
    if (pages.isEmpty) return 0;
    return pages.keys.reduce(math.max);
  }

  int _nextPageIndex(Map<int, List<ScannedDocument>> pages) {
    if (pages.isEmpty) return 0;
    return pages.keys.reduce(math.max) + 1;
  }

  Map<int, List<ScannedDocument>> _copyState(
    Map<int, List<ScannedDocument>> source,
  ) {
    return <int, List<ScannedDocument>>{
      for (final entry in source.entries)
        entry.key: List<ScannedDocument>.from(entry.value),
    };
  }

  Map<int, List<ScannedDocument>> _freeze(
    Map<int, List<ScannedDocument>> source,
  ) {
    return Map<int, List<ScannedDocument>>.unmodifiable(
      <int, List<ScannedDocument>>{
        for (final entry in source.entries)
          entry.key: List<ScannedDocument>.unmodifiable(entry.value),
      },
    );
  }
}

enum _PlacementOutcome { added, overflow }

final scannedDocumentsProvider =
    NotifierProvider<ScannedDocumentsNotifier, Map<int, List<ScannedDocument>>>(
      ScannedDocumentsNotifier.new,
    );

@immutable
class AppState {
  const AppState({
    this.hasNationalId = false,
    this.hasHousingCard = false,
    this.hasRationCard = false,
    this.hasPassport = false,
    this.hasA4Document = false,
    this.displayMethod = DisplayMethod.onePage,
    this.addFrame = false,
    this.fileName = defaultFileName,
    this.smartRecognition = false,
  });

  /// Used when the user never renamed the output file.
  static const String defaultFileName = 'مستمسكاتي';

  final bool hasNationalId;
  final bool hasHousingCard;
  final bool hasRationCard;
  final bool hasPassport;
  final bool hasA4Document;
  final DisplayMethod displayMethod;
  final bool addFrame;
  final String fileName;
  final bool smartRecognition;

  AppState copyWith({
    bool? hasNationalId,
    bool? hasHousingCard,
    bool? hasRationCard,
    bool? hasPassport,
    bool? hasA4Document,
    DisplayMethod? displayMethod,
    bool? addFrame,
    String? fileName,
    bool? smartRecognition,
  }) {
    return AppState(
      hasNationalId: hasNationalId ?? this.hasNationalId,
      hasHousingCard: hasHousingCard ?? this.hasHousingCard,
      hasRationCard: hasRationCard ?? this.hasRationCard,
      hasPassport: hasPassport ?? this.hasPassport,
      hasA4Document: hasA4Document ?? this.hasA4Document,
      displayMethod: displayMethod ?? this.displayMethod,
      addFrame: addFrame ?? this.addFrame,
      fileName: fileName ?? this.fileName,
      smartRecognition: smartRecognition ?? this.smartRecognition,
    );
  }

  /// The name to use for a generated file.
  ///
  /// The settings field stores exactly what the user typed (rewriting it under
  /// the cursor was the old bug), so the documented default is applied here at
  /// the moment the name is actually consumed.
  String get effectiveFileName {
    final trimmed = fileName.trim();
    return trimmed.isEmpty ? defaultFileName : trimmed;
  }

  /// Serialises the user's scanning preferences.
  ///
  /// Layout and scanned pages are intentionally not part of this payload: the
  /// work images live in the platform cache directory, so persisting a layout
  /// that points at them would restore broken documents after a cache purge.
  Map<String, Object?> toJson() => <String, Object?>{
    'hasNationalId': hasNationalId,
    'hasHousingCard': hasHousingCard,
    'hasRationCard': hasRationCard,
    'hasPassport': hasPassport,
    'hasA4Document': hasA4Document,
    'displayMethod': displayMethod.name,
    'addFrame': addFrame,
    'fileName': fileName,
    'smartRecognition': smartRecognition,
  };

  /// Rebuilds a state from [json], falling back per field for anything that is
  /// missing or of the wrong type (an older or partially written payload must
  /// never throw during start-up).
  factory AppState.fromJson(Map<String, Object?> json) {
    final storedName = json['fileName'];
    final fileName = storedName is String && storedName.trim().isNotEmpty
        ? storedName.trim()
        : defaultFileName;
    final storedMethod = json['displayMethod'];
    return AppState(
      hasNationalId: _boolValue(json['hasNationalId']),
      hasHousingCard: _boolValue(json['hasHousingCard']),
      hasRationCard: _boolValue(json['hasRationCard']),
      hasPassport: _boolValue(json['hasPassport']),
      hasA4Document: _boolValue(json['hasA4Document']),
      displayMethod: _displayMethodFromName(
        storedMethod is String ? storedMethod : null,
      ),
      addFrame: _boolValue(json['addFrame']),
      fileName: fileName,
      smartRecognition: _boolValue(json['smartRecognition']),
    );
  }

  /// Reads a stored boolean, treating anything unexpected as `false` instead of
  /// throwing a cast error.
  static bool _boolValue(Object? value) => value is bool ? value : false;

  static DisplayMethod _displayMethodFromName(String? name) {
    for (final method in DisplayMethod.values) {
      if (method.name == name) return method;
    }
    return DisplayMethod.onePage;
  }

  /// Returns the exact detector selection without collapsing mixed choices.
  ///
  /// A4 is intentionally exclusive: it is a full-frame document mode, not a
  /// detector that should be combined with card or passport passes.
  List<DocumentType> get selectedDocumentTypes {
    if (hasA4Document) return const <DocumentType>[DocumentType.a4Document];

    final selected = <DocumentType>[
      if (hasNationalId) DocumentType.nationalId,
      if (hasHousingCard) DocumentType.housingCard,
      if (hasRationCard) DocumentType.rationCard,
      if (hasPassport) DocumentType.passport,
    ];
    return List<DocumentType>.unmodifiable(
      selected.isEmpty
          ? const <DocumentType>[DocumentType.allDocuments]
          : selected,
    );
  }

  /// Legacy single-value projection retained for existing non-smart flows.
  DocumentType get selectedDocumentType {
    final types = selectedDocumentTypes;
    if (types.length == 1) return types.first;
    return DocumentType.allDocuments;
  }

  bool get hasAtLeastOneDocument =>
      hasNationalId ||
      hasHousingCard ||
      hasRationCard ||
      hasPassport ||
      hasA4Document;
}

class AppStateNotifier extends Notifier<AppState> {
  final AppSettingsStore _store = AppSettingsStore();

  /// True once the user changed something in this session.
  ///
  /// Needed to settle the start-up race: the preferences are read
  /// asynchronously, and a change made before that read finishes must not be
  /// overwritten by the older stored value.
  bool _hasLocalChanges = false;

  @override
  AppState build() {
    ref.onDispose(_store.dispose);
    // Persistence stays disabled until [restorePersistedState] runs, so unit
    // tests and headless callers never touch a platform channel.
    return const AppState();
  }

  /// Loads the preferences that were persisted by a previous launch.
  Future<void> restorePersistedState() async {
    final payload = await _store.loadPayload();
    if (_hasLocalChanges) {
      // The user interacted while the stored values were loading: their choice
      // is authoritative, so it is written instead of being replaced.
      await _store.flush();
      return;
    }
    if (payload == null) return;
    state = AppState.fromJson(payload);
  }

  /// Persists everything that is waiting to be written.
  Future<void> flushPersistedState() => _store.flush();

  void _update(AppState next) {
    _hasLocalChanges = true;
    state = next;
    _store.save(next.toJson());
  }

  void toggleNationalId(bool? value) =>
      _update(state.copyWith(hasNationalId: value ?? false));
  void toggleHousingCard(bool? value) =>
      _update(state.copyWith(hasHousingCard: value ?? false));
  void toggleRationCard(bool? value) =>
      _update(state.copyWith(hasRationCard: value ?? false));
  void togglePassport(bool? value) =>
      _update(state.copyWith(hasPassport: value ?? false));
  void toggleA4Document(bool? value) =>
      _update(state.copyWith(hasA4Document: value ?? false));

  void updateDisplayMethod(DisplayMethod method) =>
      _update(state.copyWith(displayMethod: method));

  void toggleAddFrame(bool value) => _update(state.copyWith(addFrame: value));

  void updateFileName(String name) => _update(state.copyWith(fileName: name));

  void toggleSmartRecognition(bool value) =>
      _update(state.copyWith(smartRecognition: value));
}

final appStateProvider = NotifierProvider<AppStateNotifier, AppState>(
  AppStateNotifier.new,
);
