import 'dart:io';

import 'package:doc_scanner_app/constants/app_constants.dart';
import 'package:doc_scanner_app/providers/app_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

ScannedDocument _document({
  required String id,
  double dx = 10,
  double dy = 20,
}) {
  return ScannedDocument(
    id: id,
    file: File('/tmp/$id.jpg'),
    originalWidth: 400,
    originalHeight: 200,
    dx: dx,
    dy: dy,
    width: 200,
    height: 100,
  );
}

void main() {
  group('ScannedDocumentsNotifier', () {
    late ProviderContainer container;
    late ScannedDocumentsNotifier notifier;

    setUp(() {
      container = ProviderContainer();
      notifier = container.read(scannedDocumentsProvider.notifier);
    });

    tearDown(() => container.dispose());

    test('updates an immutable document through its stable id', () {
      final original = _document(id: 'doc-a');
      notifier.seedDocuments(<int, List<ScannedDocument>>{
        0: <ScannedDocument>[original],
      });

      notifier.updateDocumentLayout(
        'doc-a',
        dx: 30,
        dy: 40,
        width: 200,
        height: 100,
        rotationAngle: 90,
        scale: 1.5,
      );

      final updated = notifier.findDocument('doc-a')!.document;
      expect(updated.id, 'doc-a');
      expect(updated.dx, 30);
      expect(updated.dy, 40);
      expect(updated.rotationAngle, 90);
      expect(updated.scale, 1.5);
      expect(identical(original, updated), isFalse);
      expect(original.dx, 10);
    });

    test('moves the intended document after sibling order changes', () {
      notifier.seedDocuments(<int, List<ScannedDocument>>{
        0: <ScannedDocument>[_document(id: 'first'), _document(id: 'target')],
      });
      notifier
        ..moveDocumentToTop('first')
        ..moveDocument('target', targetPageIndex: 1, dx: 12, dy: 24);

      expect(notifier.findDocument('target')!.pageIndex, 1);
      expect(notifier.findDocument('target')!.document.dx, 12);
      expect(notifier.findDocument('first')!.pageIndex, 0);
      expect(
        container
            .read(scannedDocumentsProvider)[0]!
            .map((document) => document.id),
        contains('first'),
      );
    });

    test('removes only the document matching the given id', () {
      notifier.seedDocuments(<int, List<ScannedDocument>>{
        0: <ScannedDocument>[_document(id: 'keep'), _document(id: 'remove')],
      });

      final removed = notifier.removeDocument('remove');

      expect(removed!.id, 'remove');
      expect(notifier.findDocument('remove'), isNull);
      expect(notifier.findDocument('keep'), isNotNull);
    });

    test(
      'places cropped cards side by side within a one-page layout',
      () async {
        final directory = await Directory.systemTemp.createTemp('layout_test_');
        addTearDown(() => directory.delete(recursive: true));
        final first = File('${directory.path}/first.jpg');
        final second = File('${directory.path}/second.jpg');
        final bytes = img.encodeJpg(img.Image(width: 900, height: 560));
        await first.writeAsBytes(bytes);
        await second.writeAsBytes(bytes);

        final result = await notifier.placeDocuments(<DocumentInput>[
          DocumentInput(file: first, type: DocumentType.nationalId),
          DocumentInput(file: second, type: DocumentType.nationalId),
        ], const AppState(displayMethod: DisplayMethod.onePage));

        final documents = container.read(scannedDocumentsProvider)[0]!;
        expect(result.addedDocuments, hasLength(2));
        expect(documents, hasLength(2));
        expect(
          documents[0].dx + documents[0].width,
          lessThanOrEqualTo(documents[1].dx),
        );
        expect(documents[0].dy, closeTo(documents[1].dy, 0.001));
        for (final document in documents) {
          expect(document.dx, greaterThanOrEqualTo(AppConstants.kA4GuideLeft));
          expect(document.dy, greaterThanOrEqualTo(AppConstants.kA4GuideTop));
          expect(
            document.dx + document.width,
            lessThanOrEqualTo(
              AppConstants.kA4GuideLeft + AppConstants.kA4GuideWidth,
            ),
          );
          expect(
            document.dy + document.height,
            lessThanOrEqualTo(
              AppConstants.kA4GuideTop + AppConstants.kA4GuideHeight,
            ),
          );
        }
      },
    );
  });

  test('display method is selected through an immutable AppState copy', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final initial = container.read(appStateProvider);

    container
        .read(appStateProvider.notifier)
        .updateDisplayMethod(DisplayMethod.twoPages);

    expect(
      container.read(appStateProvider).displayMethod,
      DisplayMethod.twoPages,
    );
    expect(identical(initial, container.read(appStateProvider)), isFalse);
  });
  test(
    'selects A4 as the explicit document type and counts it as selected',
    () {
      const state = AppState(hasA4Document: true);

      expect(state.selectedDocumentType, DocumentType.a4Document);
      expect(state.hasAtLeastOneDocument, isTrue);
    },
  );

  test('A4 has priority when multiple document types are enabled', () {
    const state = AppState(
      hasNationalId: true,
      hasHousingCard: true,
      hasRationCard: true,
      hasPassport: true,
      hasA4Document: true,
    );

    expect(state.selectedDocumentType, DocumentType.a4Document);
  });

  test('national ID preserves the single selected detector type', () {
    const state = AppState(hasNationalId: true);

    expect(state.selectedDocumentType, DocumentType.nationalId);
    expect(state.selectedDocumentTypes, <DocumentType>[
      DocumentType.nationalId,
    ]);
  });

  test('housing card selects the single housing-card profile', () {
    const state = AppState(hasHousingCard: true);

    expect(state.selectedDocumentType, DocumentType.housingCard);
  });

  test(
    'multiple selected card types use independent all-document discovery',
    () {
      const state = AppState(hasHousingCard: true, hasRationCard: true);

      expect(state.selectedDocumentType, DocumentType.allDocuments);
    },
  );

  test('toggles A4 through AppStateNotifier immutably', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final initial = container.read(appStateProvider);

    container.read(appStateProvider.notifier).toggleA4Document(true);

    final updated = container.read(appStateProvider);
    expect(updated.hasA4Document, isTrue);
    expect(updated.selectedDocumentType, DocumentType.a4Document);
    expect(identical(initial, updated), isFalse);
  });

  test('returns the created page index without exposing protected state', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(scannedDocumentsProvider.notifier);
    final pageIndex = notifier.forceNewPage();

    expect(pageIndex, 0);
    expect(
      container.read(scannedDocumentsProvider).containsKey(pageIndex),
      isTrue,
    );
  });

  test('an oversized document is fitted inside the A4 guide', () async {
    final directory = await Directory.systemTemp.createTemp('oversized_');
    addTearDown(() => directory.delete(recursive: true));
    final panorama = File('${directory.path}/panorama.jpg');
    // 4:1 aspect ratio, far wider than the guide.
    await panorama.writeAsBytes(
      img.encodeJpg(img.Image(width: 800, height: 200)),
    );

    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(scannedDocumentsProvider.notifier);
    await notifier.placeDocuments(<DocumentInput>[
      DocumentInput(file: panorama, type: DocumentType.a4Document),
    ], const AppState(hasA4Document: true));

    final document = container.read(scannedDocumentsProvider)[0]!.single;
    expect(document.width, lessThanOrEqualTo(AppConstants.kA4GuideWidth));
    expect(document.height, lessThanOrEqualTo(AppConstants.kA4GuideHeight));
    expect(document.width / document.height, closeTo(4, 0.01));
    expect(document.dx, greaterThanOrEqualTo(AppConstants.kA4GuideLeft));
    expect(document.dy, greaterThanOrEqualTo(AppConstants.kA4GuideTop));
  });

  test('replacing an image refits the box and keeps the centre', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(scannedDocumentsProvider.notifier);
    notifier.seedDocuments(<int, List<ScannedDocument>>{
      0: <ScannedDocument>[
        ScannedDocument(
          id: 'refit',
          file: File('/tmp/before.jpg'),
          type: DocumentType.a4Document,
          // Natural aspect 2:1, laid out away from every guide edge so the
          // refit below does not have to clamp the centre away.
          originalWidth: 1000,
          originalHeight: 500,
          dx: 150,
          dy: 200,
          width: 200,
          height: 100,
          scale: 1,
        ),
      ],
    });
    final before = notifier.findDocument('refit')!.document;
    final centerX = before.dx + (before.width * before.scale) / 2;
    final centerY = before.dy + (before.height * before.scale) / 2;

    notifier.replaceDocumentImage(
      'refit',
      file: File('/tmp/after.jpg'),
      // A portrait crop: the box has to follow the new aspect ratio.
      originalWidth: 600,
      originalHeight: 900,
    );

    final after = notifier.findDocument('refit')!.document;
    expect(after.file.path, '/tmp/after.jpg');
    expect(after.originalWidth, 600);
    expect(after.originalHeight, 900);
    expect(after.width / after.height, closeTo(600 / 900, 0.01));
    expect(after.scale, 1);
    expect(after.dx + after.width / 2, closeTo(centerX, 0.5));
    expect(after.dy + after.height / 2, closeTo(centerY, 0.5));
    expect(after.dx, greaterThanOrEqualTo(AppConstants.kA4GuideLeft));
    expect(after.dy, greaterThanOrEqualTo(AppConstants.kA4GuideTop));
    expect(
      after.dx + after.width,
      lessThanOrEqualTo(AppConstants.kA4GuideLeft + AppConstants.kA4GuideWidth),
    );
    expect(
      after.dy + after.height,
      lessThanOrEqualTo(AppConstants.kA4GuideTop + AppConstants.kA4GuideHeight),
    );
  });

  test('preserves original source metadata when moving a document', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(scannedDocumentsProvider.notifier);
    notifier.seedDocuments(<int, List<ScannedDocument>>{
      0: <ScannedDocument>[
        ScannedDocument(
          id: 'source-preserved',
          file: File('/tmp/cropped.jpg'),
          originalImagePath: '/tmp/full-source.jpg',
          originalWidth: 900,
          originalHeight: 600,
          width: 300,
          height: 200,
        ),
      ],
    });

    notifier.moveDocument(
      'source-preserved',
      targetPageIndex: 1,
      dx: 24,
      dy: 36,
    );

    final moved = notifier.findDocument('source-preserved')!.document;
    expect(moved.originalImagePath, '/tmp/full-source.jpg');
    expect(moved.originalWidth, 900);
    expect(moved.originalHeight, 600);
  });
}
