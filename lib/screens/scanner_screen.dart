import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';

import '../constants/app_constants.dart';
import '../providers/app_state.dart';
import '../services/pdf_service.dart';
import '../services/scanner_service.dart';
import '../services/temporary_image_store.dart';
import '../widgets/draggable_document.dart';
import 'archive_screen.dart';
import 'image_editor_screen.dart';
import 'multi_crop_screen.dart';
import 'settings_screen.dart';
import 'single_crop_screen.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  final ScannerService _scannerService = ScannerService();
  final PdfService _pdfService = PdfService();
  final PageController _pageController = PageController();

  String? _selectedDocumentId;
  bool _isProcessing = false;
  int _visiblePagePosition = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _scanDocument(ImageSource source) async {
    if (_isProcessing) return;
    try {
      final files = source == ImageSource.gallery
          ? await _scannerService.scanMultipleDocuments()
          : await _pickCameraFile();
      if (files == null || files.isEmpty || !mounted) return;
      await _processSourceFiles(files, source: source);
    } catch (_) {
      if (mounted) _showMessage('تعذر الوصول إلى الصورة المحددة.');
    }
  }

  Future<List<File>?> _pickCameraFile() async {
    final sourceFile = await _scannerService.scanDocument(
      source: ImageSource.camera,
    );
    if (sourceFile == null || !mounted) return null;
    final cropped = await Navigator.of(context).push<File>(
      MaterialPageRoute<File>(
        builder: (context) => SingleCropScreen(imageFile: sourceFile),
      ),
    );
    return cropped == null ? null : <File>[cropped];
  }

  Future<void> _processSourceFiles(
    List<File> sourceFiles, {
    required ImageSource source,
  }) async {
    setState(() => _isProcessing = true);
    try {
      final smartRecognition = ref.read(appStateProvider).smartRecognition;
      if (!smartRecognition) {
        final inputs = await _manuallyCropSources(sourceFiles);
        await _placeInputs(inputs);
        return;
      }

      final cancellation = ScanCancellationToken();
      final progress = ValueNotifier<int>(0);
      final dialogNavigator = Navigator.of(context, rootNavigator: true);
      var progressDialogOpen = true;
      late final DialogRoute<void> progressDialogRoute;
      late final Future<void> progressDialogFuture;

      Future<void> closeProgressDialog() async {
        if (progressDialogOpen) {
          progressDialogOpen = false;
          if (progressDialogRoute.isActive) {
            dialogNavigator.removeRoute(progressDialogRoute);
          }
        }
        await progressDialogFuture;
      }

      progressDialogRoute = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: const Text('جاري المسح الذكي'),
            content: ValueListenableBuilder<int>(
              valueListenable: progress,
              builder: (context, completed, child) => Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  LinearProgressIndicator(
                    value: sourceFiles.isEmpty
                        ? null
                        : completed / sourceFiles.length,
                  ),
                  const SizedBox(height: 16),
                  Text('معالجة $completed من ${sourceFiles.length}'),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () {
                  cancellation.cancel();
                  unawaited(closeProgressDialog());
                },
                child: const Text('إلغاء'),
              ),
            ],
          ),
        ),
      );
      progressDialogFuture = dialogNavigator.push<void>(progressDialogRoute);
      SmartScanBatchResult smartResult;
      try {
        await Future<void>.delayed(Duration.zero);
        smartResult = await _scannerService.processBatchSmartRecognition(
          sourceFiles,
          cancellationToken: cancellation,
          onProgress: (current, total) {
            if (!cancellation.isCancelled) progress.value = current;
          },
        );
      } finally {
        progress.dispose();
        try {
          await closeProgressDialog();
        } catch (_) {
          // Dialog teardown must not mask the scan result.
        }
      }

      final inputs = <DocumentInput>[];
      final manualFallbackSources = <File>[];
      var requiresClassificationReview = false;
      for (final sourceFile in sourceFiles) {
        final result = smartResult.results[sourceFile];
        if (result == null || result.files.isEmpty) {
          if (!smartResult.wasCancelled) {
            manualFallbackSources.add(sourceFile);
          }
          continue;
        }
        requiresClassificationReview |=
            result.classification.requiresManualReview;
        for (final output in result.files) {
          inputs.add(
            DocumentInput(
              file: output,
              type: result.classification.type,
              originalImagePath: sourceFile.path,
            ),
          );
        }
      }
      if (manualFallbackSources.isNotEmpty) {
        inputs.addAll(await _manuallyCropSources(manualFallbackSources));
      }
      await _placeInputs(inputs);
      if (!mounted) return;
      if (smartResult.wasCancelled) {
        _showMessage('أُلغي المسح الذكي؛ عولجت الصور المكتملة فقط.');
      } else if (requiresClassificationReview) {
        _showMessage('اكتمل القص. راجع نوع المستند يدوياً عند الحاجة.');
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<List<DocumentInput>> _manuallyCropSources(
    List<File> sourceFiles,
  ) async {
    final inputs = <DocumentInput>[];
    for (final sourceFile in sourceFiles) {
      if (!mounted) break;
      final result = await Navigator.of(context).push<List<File>>(
        MaterialPageRoute<List<File>>(
          builder: (context) => MultiCropScreen(imageFile: sourceFile),
        ),
      );
      final files = result ?? <File>[sourceFile];
      inputs.addAll(
        files.map(
          (file) =>
              DocumentInput(file: file, originalImagePath: sourceFile.path),
        ),
      );
    }
    return inputs;
  }

  Future<void> _placeInputs(List<DocumentInput> inputs) async {
    if (inputs.isEmpty) return;
    final notifier = ref.read(scannedDocumentsProvider.notifier);
    final result = await notifier.placeDocuments(
      inputs,
      ref.read(appStateProvider),
    );
    if (!mounted) return;
    if (result.addedDocuments.isNotEmpty) HapticFeedback.mediumImpact();
    if (result.failedFiles.isNotEmpty) {
      _showMessage('تعذر تحميل ${result.failedFiles.length} ملفاً تالفاً.');
    }
    if (result.skippedFiles.isNotEmpty) {
      _showMessage('طريقة العرض المختارة تقبل مستنداً واحداً فقط.');
    }
    if (result.overflowFiles.isNotEmpty) {
      await _handleOverflow(result.overflowFiles);
    }
  }

  Future<void> _handleOverflow(List<File> overflowFiles) async {
    final shouldAddPage = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('الصفحة ممتلئة'),
        content: Text(
          'هل تريد إنشاء صفحة للمستندات المتبقية (${overflowFiles.length})؟',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('إنشاء صفحة'),
          ),
        ],
      ),
    );
    if (shouldAddPage != true || !mounted) return;
    final notifier = ref.read(scannedDocumentsProvider.notifier)
      ..forceNewPage();
    final result = await notifier.placeDocuments(
      overflowFiles.map((file) => DocumentInput(file: file)).toList(),
      ref.read(appStateProvider),
    );
    if (result.overflowFiles.isNotEmpty) {
      _showMessage('لم تتسع الصفحة الجديدة لكل المستندات.');
    }
  }

  Future<void> _generatePdf() async {
    final pages = ref.read(scannedDocumentsProvider);
    if (pages.values.every((documents) => documents.isEmpty)) {
      _showMessage('أضف مستنداً واحداً على الأقل قبل إنشاء PDF.');
      return;
    }
    setState(() => _isProcessing = true);
    try {
      await _pdfService.generatePdf(
        groupedPages: pages,
        state: ref.read(appStateProvider),
        uiCanvasWidth: AppConstants.kVirtualCanvasWidth,
        uiCanvasHeight: AppConstants.kVirtualCanvasHeight,
      );
      if (!mounted) return;
      _showMessage('تم إنشاء ملف PDF بنجاح.');
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (context) => const ArchiveScreen()),
      );
    } catch (_) {
      if (mounted) _showMessage('تعذر إنشاء ملف PDF.');
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  void _selectDocument(String documentId) {
    ref.read(scannedDocumentsProvider.notifier).moveDocumentToTop(documentId);
    setState(() => _selectedDocumentId = documentId);
  }

  Future<void> _deleteSelected() async {
    final documentId = _selectedDocumentId;
    if (documentId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: const Text('هل تريد حذف المستند المحدد من هذه الصفحة؟'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final document = ref
        .read(scannedDocumentsProvider.notifier)
        .removeDocument(documentId);
    if (document != null) {
      await TemporaryImageStore.deleteIfManaged(document.file);
    }
    if (mounted) setState(() => _selectedDocumentId = null);
  }

  void _editSelected() {
    final id = _selectedDocumentId;
    if (id == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ImageEditorScreen(documentId: id),
      ),
    );
  }

  Future<void> _cropSelected() async {
    final id = _selectedDocumentId;
    if (id == null) return;
    final location = ref
        .read(scannedDocumentsProvider.notifier)
        .findDocument(id);
    if (location == null) return;
    final sourcePath =
        location.document.originalImagePath ?? location.document.file.path;
    final source = File(sourcePath);
    if (!await source.exists() || !mounted) {
      _showMessage('لا تتوفر الصورة الأصلية لإعادة القص.');
      return;
    }
    final output = await Navigator.of(context).push<File>(
      MaterialPageRoute<File>(
        builder: (context) => SingleCropScreen(imageFile: source),
      ),
    );
    if (output == null || !mounted) return;
    try {
      final decoded = await decodeImageFromList(await output.readAsBytes());
      final width = decoded.width.toDouble();
      final height = decoded.height.toDouble();
      decoded.dispose();
      final oldFile = location.document.file;
      ref
          .read(scannedDocumentsProvider.notifier)
          .updateDocument(
            id,
            file: output,
            originalWidth: width,
            originalHeight: height,
          );
      final stillUsed = ref
          .read(scannedDocumentsProvider)
          .values
          .expand((documents) => documents)
          .any((document) => document.file.path == oldFile.path);
      if (!stillUsed) await TemporaryImageStore.deleteIfManaged(oldFile);
    } catch (_) {
      await TemporaryImageStore.deleteIfManaged(output);
      if (mounted) _showMessage('تعذر اعتماد القص الجديد.');
    }
  }

  Future<void> _saveSelected() async {
    final id = _selectedDocumentId;
    if (id == null) return;
    final location = ref
        .read(scannedDocumentsProvider.notifier)
        .findDocument(id);
    if (location == null) return;
    try {
      await Gal.putImage(location.document.file.path);
      if (mounted) _showMessage('تم الحفظ في المعرض.');
    } catch (_) {
      if (mounted) _showMessage('تعذر الحفظ في المعرض.');
    }
  }

  void _rotateSelected() {
    final id = _selectedDocumentId;
    if (id == null) return;
    final location = ref
        .read(scannedDocumentsProvider.notifier)
        .findDocument(id);
    if (location == null) return;
    final document = location.document;
    final centerX = document.dx + document.width / 2;
    final centerY = document.dy + document.height / 2;
    final width = document.height;
    final height = document.width;
    final dx = (centerX - width / 2)
        .clamp(0, AppConstants.kVirtualCanvasWidth - width)
        .toDouble();
    final dy = (centerY - height / 2)
        .clamp(0, AppConstants.kVirtualCanvasHeight - height)
        .toDouble();
    ref
        .read(scannedDocumentsProvider.notifier)
        .updateDocumentLayout(
          id,
          dx: dx,
          dy: dy,
          width: width,
          height: height,
          rotationAngle: (document.rotationAngle + 90) % 360,
          scale: document.scale,
        );
  }

  void _fitSelectedToPage() {
    final id = _selectedDocumentId;
    if (id == null) return;
    final location = ref
        .read(scannedDocumentsProvider.notifier)
        .findDocument(id);
    if (location == null) return;
    final document = location.document;
    final ratio = document.originalHeight == 0
        ? 1.0
        : document.originalWidth / document.originalHeight;
    var width = AppConstants.kVirtualCanvasWidth;
    var height = width / ratio;
    if (height > AppConstants.kVirtualCanvasHeight) {
      height = AppConstants.kVirtualCanvasHeight;
      width = height * ratio;
    }
    ref
        .read(scannedDocumentsProvider.notifier)
        .updateDocumentLayout(
          id,
          dx: (AppConstants.kVirtualCanvasWidth - width) / 2,
          dy: (AppConstants.kVirtualCanvasHeight - height) / 2,
          width: width,
          height: height,
          rotationAngle: document.rotationAngle,
          scale: 1,
        );
  }

  void _moveCrossPage(String documentId, double dx, double dy) {
    final pages = ref.read(scannedDocumentsProvider);
    final pageKeys = pages.keys.toList()..sort();
    final location = ref
        .read(scannedDocumentsProvider.notifier)
        .findDocument(documentId);
    if (location == null) return;
    final currentPosition = pageKeys.indexOf(location.pageIndex);
    final movingUp = dy < 0;
    int targetPage;
    if (movingUp && currentPosition > 0) {
      targetPage = pageKeys[currentPosition - 1];
    } else if (!movingUp &&
        currentPosition >= 0 &&
        currentPosition < pageKeys.length - 1) {
      targetPage = pageKeys[currentPosition + 1];
    } else {
      ref.read(scannedDocumentsProvider.notifier).forceNewPage();
      targetPage = ref
          .read(scannedDocumentsProvider)
          .keys
          .reduce((a, b) => a > b ? a : b);
    }
    final adjustedY = movingUp
        ? AppConstants.kVirtualCanvasHeight - location.document.height
        : 0.0;
    ref
        .read(scannedDocumentsProvider.notifier)
        .moveDocument(
          documentId,
          targetPageIndex: targetPage,
          dx: dx
              .clamp(
                0,
                AppConstants.kVirtualCanvasWidth - location.document.width,
              )
              .toDouble(),
          dy: adjustedY,
        );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(scannedDocumentsProvider);
    final pageKeys = pages.keys.toList()..sort();
    final appState = ref.watch(appStateProvider);
    final selectedStillExists =
        _selectedDocumentId != null &&
        pages.values
            .expand((documents) => documents)
            .any((document) => document.id == _selectedDocumentId);
    if (!selectedStillExists && _selectedDocumentId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedDocumentId = null);
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('مسح المستمسكات'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.folder_open_outlined),
            tooltip: 'الأرشيف',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => const ArchiveScreen(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'الإعدادات',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => const SettingsScreen(),
              ),
            ),
          ),
        ],
      ),
      body: _isProcessing
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                Expanded(
                  child: pageKeys.isEmpty
                      ? _emptyState()
                      : PageView.builder(
                          controller: _pageController,
                          itemCount: pageKeys.length,
                          onPageChanged: (value) =>
                              setState(() => _visiblePagePosition = value),
                          itemBuilder: (context, index) => _buildPageCanvas(
                            pageIndex: pageKeys[index],
                            documents: pages[pageKeys[index]]!,
                            appState: appState,
                          ),
                        ),
                ),
                if (pageKeys.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'صفحة ${_visiblePagePosition + 1} من ${pageKeys.length}',
                    ),
                  ),
                _buildSelectedToolbar(),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _showImageSourceOptions,
                            icon: const Icon(Icons.add_a_photo),
                            label: const Text('إضافة مستند'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton.filled(
                          onPressed: _generatePdf,
                          icon: const Icon(Icons.picture_as_pdf),
                          tooltip: 'إنشاء PDF',
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(
            Icons.document_scanner_outlined,
            size: 72,
            color: Colors.grey,
          ),
          const SizedBox(height: 16),
          const Text('لم تُضف أي مستندات بعد.'),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _showImageSourceOptions,
            icon: const Icon(Icons.add),
            label: const Text('ابدأ المسح'),
          ),
        ],
      ),
    );
  }

  Widget _buildPageCanvas({
    required int pageIndex,
    required List<ScannedDocument> documents,
    required AppState appState,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasScale =
            constraints.maxWidth / AppConstants.kVirtualCanvasWidth;
        final displayHeight = AppConstants.kVirtualCanvasHeight * canvasScale;
        return Center(
          child: SizedBox(
            width: constraints.maxWidth,
            height: displayHeight,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.blueGrey.shade100),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(color: Colors.black12, blurRadius: 6),
                  ],
                ),
                child: Transform.scale(
                  scale: canvasScale,
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: AppConstants.kVirtualCanvasWidth,
                    height: AppConstants.kVirtualCanvasHeight,
                    child: Stack(
                      clipBehavior: Clip.hardEdge,
                      children: documents
                          .map(
                            (document) => DraggableResizableDocument(
                              key: ValueKey(document.id),
                              document: document,
                              isSelected: document.id == _selectedDocumentId,
                              addFrame: appState.addFrame,
                              canvasWidth: AppConstants.kVirtualCanvasWidth,
                              canvasHeight: AppConstants.kVirtualCanvasHeight,
                              canvasScale: canvasScale,
                              onTap: _selectDocument,
                              onLayoutUpdate: (id, dx, dy, scale) {
                                final current = ref
                                    .read(scannedDocumentsProvider.notifier)
                                    .findDocument(id);
                                if (current == null) return;
                                ref
                                    .read(scannedDocumentsProvider.notifier)
                                    .updateDocumentLayout(
                                      id,
                                      dx: dx,
                                      dy: dy,
                                      width: current.document.width,
                                      height: current.document.height,
                                      rotationAngle:
                                          current.document.rotationAngle,
                                      scale: scale,
                                    );
                              },
                              onCrossPageMove: _moveCrossPage,
                              onGestureStart: () =>
                                  _selectDocument(document.id),
                            ),
                          )
                          .toList(growable: false),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectedToolbar() {
    final enabled = _selectedDocumentId != null;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SizedBox(
        height: 56,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            _toolButton(
              Icons.edit_outlined,
              'تعديل',
              enabled ? _editSelected : null,
            ),
            _toolButton(
              Icons.crop_outlined,
              'قص',
              enabled ? _cropSelected : null,
            ),
            _toolButton(
              Icons.rotate_right,
              'تدوير',
              enabled ? _rotateSelected : null,
            ),
            _toolButton(
              Icons.fit_screen,
              'ملء الصفحة',
              enabled ? _fitSelectedToPage : null,
            ),
            _toolButton(Icons.save_alt, 'حفظ', enabled ? _saveSelected : null),
            _toolButton(
              Icons.delete_outline,
              'حذف',
              enabled ? _deleteSelected : null,
              color: Colors.red,
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolButton(
    IconData icon,
    String label,
    VoidCallback? onPressed, {
    Color? color,
  }) {
    return IconButton(
      icon: Icon(icon, color: onPressed == null ? null : color),
      tooltip: label,
      onPressed: onPressed,
    );
  }

  void _showImageSourceOptions() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('الكاميرا'),
              onTap: () {
                Navigator.pop(context);
                _scanDocument(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('المعرض'),
              onTap: () {
                Navigator.pop(context);
                _scanDocument(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }
}
