import 'dart:io';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter/services.dart';
import '../providers/app_state.dart';
import '../services/scanner_service.dart';
import '../services/pdf_service.dart';
import '../widgets/draggable_document.dart';
import 'image_editor_screen.dart';
import 'archive_screen.dart';
import 'multi_crop_screen.dart';
import '../constants/app_constants.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  final ScannerService _scannerService = ScannerService();
  final PdfService _pdfService = PdfService();

  bool _isProcessing = false;

  // Use ValueNotifier for localized state updates to prevent full-screen rebuilds
  final ValueNotifier<({int? pageIndex, int? docIndex})> _selectionNotifier = ValueNotifier((pageIndex: null, docIndex: null));

  double _lastKnownCanvasWidth = 380.0;
  double _lastKnownCanvasHeight = 537.32;

  Future<void> _scanDocument(ImageSource source) async {
    try {
      if (source == ImageSource.gallery) {
        final List<File>? files = await _scannerService.scanMultipleDocuments();
        if (files == null || files.isEmpty) return;

        if (!mounted) return;

        final bool smartRecog = ref.read(appStateProvider).smartRecognition;
        if (smartRecog) {
          final progressNotifier = ValueNotifier<int>(0);
          int totalImages = files.length;

          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) {
              return PopScope(
                canPop: false,
                child: AlertDialog(
                  title: const Text('جاري المعالجة', textAlign: TextAlign.right),
                  content: ValueListenableBuilder<int>(
                    valueListenable: progressNotifier,
                    builder: (context, currentProgress, child) {
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          LinearProgressIndicator(
                            value: totalImages > 0 ? currentProgress / totalImages : null,
                          ),
                          const SizedBox(height: 16),
                          Text('جاري معالجة الصورة $currentProgress من $totalImages'),
                        ],
                      );
                    },
                  ),
                ),
              );
            },
          );

          final Map<File, List<File>> mappedProcessedFiles = await _scannerService.processBatchSmartRecognition(
            files,
            onProgress: (current, total) {
              progressNotifier.value = current;
            }
          );

          if (!mounted) return;
          Navigator.pop(context); // Close dialog
          progressNotifier.dispose();

          int totalProcessed = mappedProcessedFiles.values.fold(0, (sum, list) => sum + list.length);

          if (totalProcessed == 0) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('تعذر القص الذكي، تم التحويل للقص اليدوي')),
            );

            // Push to MultiCropScreen with all original images
            for (File originalFile in files) {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => MultiCropScreen(imageFile: originalFile),
                ),
              );
              if (result != null && result is List<File>) {
                await _processBatchFiles(result, originalImagePath: originalFile.path);
              } else if (result != null && result is List<dynamic>) {
                await _processBatchFiles(result.cast<String>().map((path) => File(path)).toList(), originalImagePath: originalFile.path);
              }
            }
          } else {
            for (var entry in mappedProcessedFiles.entries) {
              if (entry.value.isNotEmpty) {
                await _processBatchFiles(entry.value, originalImagePath: entry.key.path);
              }
            }

            // Partial Detection Banner
            ScaffoldMessenger.of(context).showMaterialBanner(
              MaterialBanner(
                content: Text('تم استخراج $totalProcessed مستمسك. هل هناك مستمسكات ناقصة؟'),
                actions: [
                  TextButton(
                    onPressed: () async {
                      ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
                      for (File originalFile in files) {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => MultiCropScreen(imageFile: originalFile),
                          ),
                        );
                        if (result != null && result is List<File>) {
                          await _processBatchFiles(result, originalImagePath: originalFile.path);
                        } else if (result != null && result is List<dynamic>) {
                          await _processBatchFiles(result.cast<String>().map((path) => File(path)).toList(), originalImagePath: originalFile.path);
                        }
                      }
                    },
                    child: const Text('إضافة يدوياً'),
                  ),
                ],
              ),
            );
            Future.delayed(const Duration(seconds: 5), () {
              if (mounted) {
                ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
              }
            });
          }
          return;
        } else {
          // If Smart Crop toggle is OFF, immediately route to Manual Multi-Crop sequentially
          for (File originalFile in files) {
            final result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => MultiCropScreen(imageFile: originalFile),
              ),
            );
            if (result != null && result is List<File>) {
              await _processBatchFiles(result, originalImagePath: originalFile.path);
            } else if (result != null && result is List<dynamic>) {
              await _processBatchFiles(result.cast<String>().map((path) => File(path)).toList(), originalImagePath: originalFile.path);
            } else {
              // Fallback if null
              await _processBatchFiles([originalFile], originalImagePath: originalFile.path);
            }
          }
          return;
        }
      } else {
        final File? file = await _scannerService.scanDocument(source: source);
        if (file == null) return;

        setState(() {
          _isProcessing = true;
        });

        if (mounted) {
          final bool smartRecog = ref.read(appStateProvider).smartRecognition;
          List<File> allBatchFiles = [];

          final docType = await _scannerService.classifyDocument(file);
          List<File> finalFiles = [file];

          if (smartRecog) {
            finalFiles = await _scannerService.processSmartRecognition(file);
            if (finalFiles.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('تعذر القص الذكي، تم التحويل للقص اليدوي')),
              );
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => MultiCropScreen(imageFile: file),
                ),
              );
              if (result != null && result is List<File>) {
                finalFiles = result;
              } else if (result != null && result is List<dynamic>) {
                finalFiles = result.cast<String>().map((path) => File(path)).toList();
              } else {
                finalFiles = [file];
              }
              await _processBatchFiles(finalFiles, originalImagePath: file.path);
              return;
            } else {
              ScaffoldMessenger.of(context).showMaterialBanner(
                MaterialBanner(
                  content: Text('تم استخراج ${finalFiles.length} مستمسك. هل هناك مستمسكات ناقصة؟'),
                  actions: [
                    TextButton(
                      onPressed: () async {
                        ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => MultiCropScreen(imageFile: file),
                          ),
                        );
                        if (result != null && result is List<File>) {
                          await _processBatchFiles(result, originalImagePath: file.path);
                        } else if (result != null && result is List<dynamic>) {
                          await _processBatchFiles(result.cast<String>().map((path) => File(path)).toList(), originalImagePath: file.path);
                        }
                      },
                      child: const Text('إضافة يدوياً'),
                    ),
                  ],
                ),
              );
              Future.delayed(const Duration(seconds: 5), () {
                if (mounted) {
                  ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
                }
              });
            }
          } else {
            // Smart Recognition OFF
            final result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => MultiCropScreen(imageFile: file),
              ),
            );
            if (result != null && result is List<File>) {
              finalFiles = result;
            } else if (result != null && result is List<dynamic>) {
              finalFiles = result.cast<String>().map((path) => File(path)).toList();
            }
            await _processBatchFiles(finalFiles, originalImagePath: file.path);
            return;
          }
          allBatchFiles.addAll(finalFiles);

          if (allBatchFiles.isNotEmpty) {
            await _processBatchFiles(allBatchFiles, originalImagePath: file.path);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('حدث خطأ: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }


  Future<void> _processBatchFiles(List<File> files, {String? originalImagePath}) async {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final appState = ref.read(appStateProvider);
      final result = await ref.read(scannedDocumentsProvider.notifier).batchAddDocuments(files, appState, originalImagePath: originalImagePath);
      if (!mounted) return;
      Navigator.pop(context); // pop loading dialog

      if (result.addedDocuments.isNotEmpty) {
        HapticFeedback.mediumImpact();
      }

      if (result.failedFiles.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('فشل تحميل ${result.failedFiles.length} مستندات. قد تكون تالفة.')),
        );
      }

      if (result.overflowFiles.isNotEmpty) {
        await showDialog(
          context: context,
          builder: (context) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
              title: const Text('الصفحة ممتلئة'),
              content: Text('لم يتبق مساحة كافية. هل تريد إنشاء صفحة جديدة لـ ${result.overflowFiles.length} مستندات متبقية؟'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('إلغاء'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    ref.read(scannedDocumentsProvider.notifier).forceNewPage();
                    await _processBatchFiles(result.overflowFiles);
                  },
                  child: const Text('إنشاء صفحة'),
                ),
              ],
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // pop loading dialog
      rethrow;
    }
  }

  void _showImageSourceOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
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

  Future<void> _generatePdf() async {
    final pages = ref.read(scannedDocumentsProvider);
    if (pages.isEmpty) return;

    setState(() {
      _isProcessing = true;
    });

    try {
      final state = ref.read(appStateProvider);
      final pdfFile = await _pdfService.generatePdf(
        groupedPages: pages,
        state: state,
        uiCanvasWidth: AppConstants.kVirtualCanvasWidth,
        uiCanvasHeight: AppConstants.kVirtualCanvasHeight,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم إنشاء ملف PDF: ${pdfFile.path}')),
        );
        Navigator.push(
          context,
          MaterialPageRoute(builder: (context) => const ArchiveScreen()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('حدث خطأ: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }


  Future<void> _handleDelete(({int? pageIndex, int? docIndex}) selection) async {
    final pageIndex = selection.pageIndex;
    final docIndex = selection.docIndex;
    if (pageIndex == null || docIndex == null) return;

    final allDocs = ref.read(scannedDocumentsProvider);
    final pageDocs = allDocs[pageIndex] ?? [];
    if (docIndex >= pageDocs.length) return;
    final doc = pageDocs[docIndex];

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: const Text('هل أنت متأكد من أنك تريد حذف هذا المستمسك؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () {
              final currentAllDocs = ref.read(scannedDocumentsProvider);
              final currentDocs = currentAllDocs[pageIndex] ?? [];
              int actualIndex = currentDocs.indexWhere((d) => d.file.path == doc.file.path);
              if (actualIndex == -1) actualIndex = docIndex;
              ref.read(scannedDocumentsProvider.notifier).removeDocumentAt(pageIndex, actualIndex);

              if (_selectionNotifier.value.pageIndex == pageIndex && _selectionNotifier.value.docIndex == docIndex) {
                _selectionNotifier.value = (pageIndex: null, docIndex: null);
              } else if (_selectionNotifier.value.pageIndex == pageIndex && _selectionNotifier.value.docIndex != null && _selectionNotifier.value.docIndex! > docIndex) {
                _selectionNotifier.value = (pageIndex: _selectionNotifier.value.pageIndex, docIndex: _selectionNotifier.value.docIndex! - 1);
              }

              if (doc.file.existsSync() && doc.file.path != doc.originalImagePath) {
                try {
                  doc.file.deleteSync();
                } catch (e) {
                  debugPrint('Failed to delete cropped file: $e');
                }
              }

              if (doc.originalImagePath != null) {
                bool isShared = false;
                final currentState = ref.read(scannedDocumentsProvider);
                for (var pDocs in currentState.values) {
                  if (pDocs.any((d) => d.originalImagePath == doc.originalImagePath)) {
                    isShared = true;
                    break;
                  }
                }

                if (!isShared) {
                  final originalFile = File(doc.originalImagePath!);
                  if (originalFile.existsSync()) {
                    try {
                      originalFile.deleteSync();
                    } catch (e) {
                      debugPrint('Failed to delete original file: $e');
                    }
                  }
                }
              }

              Navigator.pop(context);
            },
            child: const Text('حذف', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _handleEdit(({int? pageIndex, int? docIndex}) selection) {
    final pageIndex = selection.pageIndex;
    final docIndex = selection.docIndex;
    if (pageIndex == null || docIndex == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ImageEditorScreen(
          pageIndex: pageIndex,
          documentIndex: docIndex
        ),
      ),
    );
  }

  Future<void> _handleCrop(({int? pageIndex, int? docIndex}) selection) async {
    final pageIndex = selection.pageIndex;
    final docIndex = selection.docIndex;
    if (pageIndex == null || docIndex == null) return;

    final allDocs = ref.read(scannedDocumentsProvider);
    final pageDocs = allDocs[pageIndex] ?? [];
    if (docIndex >= pageDocs.length) return;
    final doc = pageDocs[docIndex];

    if (doc.originalImagePath == null) return;

    final cropped = await _scannerService.manualCrop(doc.originalImagePath!);
    if (cropped != null) {
      final bytes = await cropped.readAsBytes();
      final decoded = await decodeImageFromList(bytes);
      final double newOrigWidth = decoded.width.toDouble();
      final double newOrigHeight = decoded.height.toDouble();
      decoded.dispose();

      final updatedDoc = doc.copyWith(
        file: cropped,
        originalWidth: newOrigWidth,
        originalHeight: newOrigHeight,
      );

      ref.read(scannedDocumentsProvider.notifier).updateDocumentAt(pageIndex, docIndex, updatedDoc);

      if (doc.file.existsSync() && doc.file.path != doc.originalImagePath) {
        try {
          doc.file.deleteSync();
        } catch (e) {
          debugPrint('Failed to delete old cropped file: $e');
        }
      }
    }
  }

  Future<void> _handleSave(({int? pageIndex, int? docIndex}) selection) async {
    final pageIndex = selection.pageIndex;
    final docIndex = selection.docIndex;
    if (pageIndex == null || docIndex == null) return;

    final allDocs = ref.read(scannedDocumentsProvider);
    final pageDocs = allDocs[pageIndex] ?? [];
    if (docIndex >= pageDocs.length) return;
    final doc = pageDocs[docIndex];

    try {
      await Gal.putImage(doc.file.path);
      if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تم الحفظ في المعرض')));
      }
    } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطأ في الحفظ: $e')));
        }
    }
  }

  void _handleRotate(({int? pageIndex, int? docIndex}) selection) {
    HapticFeedback.lightImpact();
    final pageIndex = selection.pageIndex;
    final docIndex = selection.docIndex;
    if (pageIndex == null || docIndex == null) return;

    final allDocs = ref.read(scannedDocumentsProvider);
    final pageDocs = allDocs[pageIndex] ?? [];
    if (docIndex >= pageDocs.length) return;
    final doc = pageDocs[docIndex];

    double centerX = doc.dx + doc.width / 2;
    double centerY = doc.dy + doc.height / 2;

    double newWidth = doc.height;
    double newHeight = doc.width;

    double newDx = centerX - newWidth / 2;
    double newDy = centerY - newHeight / 2;

    if (newDx < 0) newDx = 0;
    if (newDy < 0) newDy = 0;
    if (newDx + newWidth > AppConstants.kVirtualCanvasWidth) newDx = AppConstants.kVirtualCanvasWidth - newWidth;
    if (newDy + newHeight > AppConstants.kVirtualCanvasHeight) newDy = AppConstants.kVirtualCanvasHeight - newHeight;

    int newRotation = (doc.rotationAngle + 90) % 360;

    ref.read(scannedDocumentsProvider.notifier).updateDocumentLayout(
      pageIndex,
      docIndex,
      dx: newDx,
      dy: newDy,
      width: newWidth,
      height: newHeight,
      rotationAngle: newRotation
    );
  }

  void _handleScale(({int? pageIndex, int? docIndex}) selection) {
    HapticFeedback.lightImpact();
    final pageIndex = selection.pageIndex;
    final docIndex = selection.docIndex;
    if (pageIndex == null || docIndex == null) return;

    final allDocs = ref.read(scannedDocumentsProvider);
    final pageDocs = allDocs[pageIndex] ?? [];
    if (docIndex >= pageDocs.length) return;
    final doc = pageDocs[docIndex];

    double aspectRatio = doc.width / doc.height;

    double newWidth = AppConstants.kVirtualCanvasWidth;
    double newHeight = newWidth / aspectRatio;

    if (newHeight > AppConstants.kVirtualCanvasHeight) {
      newHeight = AppConstants.kVirtualCanvasHeight;
      newWidth = newHeight * aspectRatio;
    }

    ref.read(scannedDocumentsProvider.notifier).updateDocumentLayout(
      pageIndex,
      docIndex,
      dx: 0.0,
      dy: 0.0,
      width: newWidth,
      height: newHeight,
    );
  }


  Widget _buildDivider() {
    return Container(
      height: 24,
      width: 1,
      color: Colors.grey.withValues(alpha: 0.3),
      margin: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  Widget _globalToolbarButton(IconData icon, Color color, VoidCallback? onTap, String tooltip) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap != null ? () {
            HapticFeedback.lightImpact();
            onTap();
          } : null,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Center(
              child: Icon(icon, size: 20, color: onTap != null ? color : Colors.grey),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(scannedDocumentsProvider);
    final pageKeys = pages.keys.toList()..sort();
    final appState = ref.watch(appStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('مسح المستمسكات'),
      ),
      backgroundColor: const Color(0xFFF1F5F9),
      body: _isProcessing
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: pages.isEmpty
                      ? const Center(child: Text('لم يتم مسح أي مستمسكات بعد'))
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          clipBehavior: Clip.none,
                          itemCount: pageKeys.length,
                          separatorBuilder: (context, index) => const SizedBox(height: 20),
                          itemBuilder: (context, pageIndex) {
                            final pageKey = pageKeys[pageIndex];
                            final pageDocs = pages[pageKey]!;
                            final docsOnPage = pageDocs.asMap().entries.toList();

                            return Center(
                              child: Container(
                                clipBehavior: Clip.none,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.1),
                                      blurRadius: 10,
                                      spreadRadius: 2,
                                    )
                                  ],
                                ),
                                child: AspectRatio(
                                  aspectRatio: 1 / 1.414,
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final canvasWidth = constraints.maxWidth;
                                      final canvasHeight = constraints.maxHeight;

                                      WidgetsBinding.instance.addPostFrameCallback((_) {
                                        if (mounted && (_lastKnownCanvasWidth != canvasWidth || _lastKnownCanvasHeight != canvasHeight)) {
                                          _lastKnownCanvasWidth = canvasWidth;
                                          _lastKnownCanvasHeight = canvasHeight;
                                        }
                                      });

                                      return ValueListenableBuilder<({int? pageIndex, int? docIndex})>(
                                        valueListenable: _selectionNotifier,
                                        builder: (context, selection, child) {
                                          // Direct array rendering since Riverpod array reordering guarantees Z-Index
                                          final sortedDocs = List.of(docsOnPage);

                                          return FittedBox(
                                            fit: BoxFit.contain,
                                            clipBehavior: Clip.none,
                                            child: SizedBox(
                                              width: AppConstants.kVirtualCanvasWidth,
                                              height: AppConstants.kVirtualCanvasHeight,
                                              child: GestureDetector(
                                                behavior: HitTestBehavior.translucent,
                                                onTap: () {
                                                  _selectionNotifier.value = (pageIndex: null, docIndex: null);
                                                },
                                                child: Stack(
                                                  clipBehavior: Clip.none,
                                                  children: [
                                                    ...sortedDocs.map((entry) {
                                                      final docIndex = entry.key;
                                                      final doc = entry.value;

                                                      return DraggableResizableDocument(
                                                        key: ValueKey('${pageKey}_${doc.file.path}'),
                                                        document: doc,
                                                        pageIndex: pageKey,
                                                        docIndex: docIndex,
                                                        isSelected: selection.pageIndex == pageKey && selection.docIndex == docIndex,
                                                        addFrame: appState.addFrame,
                                                        canvasWidth: AppConstants.kVirtualCanvasWidth,
                                                        canvasHeight: AppConstants.kVirtualCanvasHeight,
                                                        canvasScale: constraints.maxWidth / AppConstants.kVirtualCanvasWidth,
                                                        onResizeUpdate: (details) {
                                                            double aspect = doc.width / doc.height;
                                                            double newWidth = doc.width + details.delta.dx / (constraints.maxWidth / AppConstants.kVirtualCanvasWidth);
                                                            double newHeight = newWidth / aspect;
                                                            ref.read(scannedDocumentsProvider.notifier).updateDocumentLayout(
                                                              pageKey, docIndex, dx: doc.dx, dy: doc.dy, width: newWidth, height: newHeight, rotationAngle: doc.rotationAngle
                                                            );
                                                        },
                                                        onResizeEnd: (details) {
                                                        },
                                                        onDragStarted: () {
                                                          int actualIndex = docIndex;
                                                          final currentDocs = ref.read(scannedDocumentsProvider)[pageKey] ?? [];
                                                          actualIndex = currentDocs.indexWhere((d) => d.file.path == doc.file.path);
                                                          if (actualIndex == -1) actualIndex = docIndex;

                                                          ref.read(scannedDocumentsProvider.notifier).moveDocumentToTop(pageKey, actualIndex);
                                                          final currentDocsCount = ref.read(scannedDocumentsProvider)[pageKey]?.length ?? 0;
                                                          _selectionNotifier.value = (pageIndex: pageKey, docIndex: currentDocsCount > 0 ? currentDocsCount - 1 : actualIndex);
                                                        },
                                                        onTap: () {
                                                          int actualIndex = docIndex;
                                                          final currentDocs = ref.read(scannedDocumentsProvider)[pageKey] ?? [];
                                                          actualIndex = currentDocs.indexWhere((d) => d.file.path == doc.file.path);
                                                          if (actualIndex == -1) actualIndex = docIndex;

                                                          if (selection.pageIndex != pageKey || selection.docIndex != actualIndex) {
                                                            ref.read(scannedDocumentsProvider.notifier).moveDocumentToTop(pageKey, actualIndex);
                                                            final currentDocsCount = ref.read(scannedDocumentsProvider)[pageKey]?.length ?? 0;
                                                            _selectionNotifier.value = (pageIndex: pageKey, docIndex: currentDocsCount > 0 ? currentDocsCount - 1 : actualIndex);
                                                          }
                                                        },
                                                        onLayoutUpdate: (pIndex, dIndex, dx, dy, width, height, rotationAngle) {
                                                          ref.read(scannedDocumentsProvider.notifier).updateDocumentLayout(
                                                            pIndex,
                                                            dIndex,
                                                            dx: dx,
                                                            dy: dy,
                                                            width: width,
                                                            height: height,
                                                            rotationAngle: rotationAngle,
                                                            originalDoc: doc,
                                                          );
                                                        },
                                                        onCrossPageMove: (sourcePageIndex, dIndex, movedDoc, dx, dy) {
                                                          final currentState = ref.read(scannedDocumentsProvider);

                                                          int targetPageKey = sourcePageIndex;
                                                          double newDy = dy;

                                                          if (dy < 0) {
                                                            // Find previous page
                                                            final pages = currentState.keys.toList()..sort();
                                                            final idx = pages.indexOf(sourcePageIndex);
                                                            if (idx > 0) {
                                                              targetPageKey = pages[idx - 1];
                                                              newDy = AppConstants.kVirtualCanvasHeight - movedDoc.height - 20.0;
                                                            } else {
                                                              newDy = 0.0;
                                                            }
                                                          } else if (dy > AppConstants.kVirtualCanvasHeight) {
                                                            // Find next page
                                                            final pages = currentState.keys.toList()..sort();
                                                            final idx = pages.indexOf(sourcePageIndex);
                                                            if (idx < pages.length - 1) {
                                                              targetPageKey = pages[idx + 1];
                                                              newDy = 20.0;
                                                            } else {
                                                              newDy = AppConstants.kVirtualCanvasHeight - movedDoc.height;
                                                            }
                                                          }

                                                          if (targetPageKey != sourcePageIndex) {
                                                            // Remove from source
                                                            ref.read(scannedDocumentsProvider.notifier).removeDocumentAt(sourcePageIndex, dIndex);

                                                            // Add to target
                                                            final updatedState = ref.read(scannedDocumentsProvider);
                                                            final targetPageDocs = updatedState[targetPageKey] ?? [];

                                                            ScannedDocument newDoc = movedDoc.copyWith(dx: dx, dy: newDy);

                                                            ref.read(scannedDocumentsProvider.notifier).setRawState( {
                                                              ...updatedState,
                                                              targetPageKey: [...targetPageDocs, newDoc],
                                                            });

                                                            _selectionNotifier.value = (pageIndex: targetPageKey, docIndex: targetPageDocs.length);
                                                          } else {
                                                            ref.read(scannedDocumentsProvider.notifier).updateDocumentLayout(
                                                              sourcePageIndex,
                                                              dIndex,
                                                              dx: dx,
                                                              dy: newDy,
                                                              width: movedDoc.width,
                                                              height: movedDoc.height,
                                                            );
                                                          }
                                                        }
                                                      );
                                                    }).toList(),

                                                    Positioned(
                                                      bottom: 24,
                                                      left: 16,
                                                      right: 16,
                                                      child: IgnorePointer(
                                                        ignoring: selection.pageIndex == null,
                                                        child: AnimatedSlide(
                                                          duration: const Duration(milliseconds: 250),
                                                          curve: Curves.easeOutBack,
                                                          offset: selection.pageIndex != null ? Offset.zero : const Offset(0, 1.5),
                                                          child: AnimatedOpacity(
                                                            duration: const Duration(milliseconds: 200),
                                                            opacity: selection.pageIndex != null ? 1.0 : 0.0,
                                                            child: Center(
                                                              child: Material(
                                                                color: Colors.transparent,
                                                                child: Container(
                                                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                                                  decoration: BoxDecoration(
                                                                    color: Theme.of(context).cardColor,
                                                                    borderRadius: BorderRadius.circular(30),
                                                                    boxShadow: [
                                                                      BoxShadow(
                                                                        color: Colors.black.withValues(alpha: 0.15),
                                                                        blurRadius: 15, offset: const Offset(0, 5),
                                                                      ),
                                                                    ],
                                                                  ),
                                                                  child: SingleChildScrollView(
                                                                    scrollDirection: Axis.horizontal,
                                                                    child: Row(
                                                                      mainAxisSize: MainAxisSize.min,
                                                                      children: [
                                                                        _globalToolbarButton(Icons.close, Colors.red, selection.pageIndex != null ? () => _handleDelete(selection) : null, 'حذف'),
                                                                        _globalToolbarButton(Icons.download, Colors.green, selection.pageIndex != null ? () => _handleSave(selection) : null, 'حفظ'),
                                                                        _buildDivider(),
                                                                        _globalToolbarButton(Icons.edit, Colors.blue, selection.pageIndex != null ? () => _handleEdit(selection) : null, 'تعديل'),
                                                                        _globalToolbarButton(Icons.crop, Colors.blue, selection.pageIndex != null ? () => _handleCrop(selection) : null, 'قص'),
                                                                        _buildDivider(),
                                                                        _globalToolbarButton(Icons.rotate_right, Colors.blue, selection.pageIndex != null ? () => _handleRotate(selection) : null, 'تدوير'),
                                                                      ],
                                                                    ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    ),
],
                                                ),
                                              ),
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                // Add New Page Button
                if (pages.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: ElevatedButton(
                      onPressed: (pages.isNotEmpty && pages[pageKeys.last]!.isEmpty)
                          ? null
                          : () {
                              HapticFeedback.lightImpact();
                              ref.read(scannedDocumentsProvider.notifier).forceNewPage();
                            },
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add),
                          SizedBox(width: 8),
                          Text('أضف صفحة جديدة', style: TextStyle(fontSize: 16)),
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Tooltip(
                          message: 'إضافة صورة جديدة',
                          child: _ScalingButton(
                            child: ElevatedButton.icon(
                              onPressed: () {
                                HapticFeedback.mediumImpact();
                                _showImageSourceOptions();
                              },
                              icon: const Icon(Icons.camera_alt),
                              label: const Text('إضافة صورة'),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Tooltip(
                          message: 'إنشاء وحفظ ملف PDF',
                          child: _ScalingButton(
                            child: ElevatedButton.icon(
                              onPressed: pages.isEmpty ? null : () {
                                HapticFeedback.mediumImpact();
                                _generatePdf();
                              },
                              icon: const Icon(Icons.picture_as_pdf),
                              label: const Text('إنشاء PDF'),
                              style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _ScalingButton extends StatefulWidget {
  final Widget child;
  const _ScalingButton({required this.child});

  @override
  State<_ScalingButton> createState() => _ScalingButtonState();
}

class _ScalingButtonState extends State<_ScalingButton> {
  bool isPressed = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: isPressed ? 0.95 : 1.0,
      duration: const Duration(milliseconds: 100),
      child: Listener(
        onPointerDown: (_) => setState(() => isPressed = true),
        onPointerUp: (_) => setState(() => isPressed = false),
        onPointerCancel: (_) => setState(() => isPressed = false),
        child: widget.child,
      ),
    );
  }
}
