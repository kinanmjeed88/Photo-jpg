import 'dart:io';
import 'package:flutter/material.dart';
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

          final processedFiles = await _scannerService.processBatchSmartRecognition(
            files,
            onProgress: (current, total) {
              progressNotifier.value = current;
            }
          );

          if (!mounted) return;
          Navigator.pop(context); // Close dialog
          progressNotifier.dispose();

          if (processedFiles.isEmpty) {
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
            await _processBatchFiles(processedFiles);
            // Partial Detection Banner
            ScaffoldMessenger.of(context).showMaterialBanner(
              MaterialBanner(
                content: Text('تم استخراج ${processedFiles.length} مستمسك. هل هناك مستمسكات ناقصة؟'),
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
                          itemCount: pageKeys.length,
                          separatorBuilder: (context, index) => const SizedBox(height: 20),
                          itemBuilder: (context, pageIndex) {
                            final pageKey = pageKeys[pageIndex];
                            final pageDocs = pages[pageKey]!;
                            final docsOnPage = pageDocs.asMap().entries.toList();

                            return Center(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
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
                                          final sortedDocs = List.of(docsOnPage);
                                          sortedDocs.sort((a, b) {
                                            bool aSelected = (selection.pageIndex == pageKey && selection.docIndex == a.key);
                                            bool bSelected = (selection.pageIndex == pageKey && selection.docIndex == b.key);
                                            if (aSelected) return 1;
                                            if (bSelected) return -1;
                                            return 0;
                                          });

                                          return FittedBox(
                                            fit: BoxFit.contain,
                                            child: SizedBox(
                                              width: AppConstants.kVirtualCanvasWidth,
                                              height: AppConstants.kVirtualCanvasHeight,
                                              child: GestureDetector(
                                                behavior: HitTestBehavior.translucent,
                                                onTap: () {
                                                  _selectionNotifier.value = (pageIndex: null, docIndex: null);
                                                },
                                                child: Stack(
                                                  clipBehavior: Clip.hardEdge,
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
                                                        onDragStarted: () {
                                                          ref.read(scannedDocumentsProvider.notifier).moveDocumentToTop(pageKey, docIndex);
                                                          final currentDocsCount = ref.read(scannedDocumentsProvider)[pageKey]?.length ?? 0;
                                                          _selectionNotifier.value = (pageIndex: pageKey, docIndex: currentDocsCount > 0 ? currentDocsCount - 1 : docIndex);
                                                        },
                                                        onTap: () {
                                                          if (selection.pageIndex != pageKey || selection.docIndex != docIndex) {
                                                            ref.read(scannedDocumentsProvider.notifier).moveDocumentToTop(pageKey, docIndex);
                                                            final currentDocsCount = ref.read(scannedDocumentsProvider)[pageKey]?.length ?? 0;
                                                            _selectionNotifier.value = (pageIndex: pageKey, docIndex: currentDocsCount > 0 ? currentDocsCount - 1 : docIndex);
                                                          }
                                                        },
                                                        onRecrop: doc.originalImagePath != null
                                                            ? () async {
                                                                final cropped = await _scannerService.manualCrop(doc.originalImagePath!);
                                                                if (cropped != null) {
                                                                  // Get fresh bytes to recalculate sizes
                                                                  final bytes = await cropped.readAsBytes();
                                                                  final decoded = await decodeImageFromList(bytes);
                                                                  final double newOrigWidth = decoded.width.toDouble();
                                                                  final double newOrigHeight = decoded.height.toDouble();
                                                                  decoded.dispose();

                                                                  final updatedDoc = doc.copyWith(
                                                                    file: cropped,
                                                                    originalWidth: newOrigWidth,
                                                                    originalHeight: newOrigHeight,
                                                                    // We preserve dx, dy, width, height, and rotationAngle as requested,
                                                                    // but visually aspect ratio will fix itself due to originalWidth/Height update.
                                                                  );
                                                                  ref.read(scannedDocumentsProvider.notifier).updateDocumentAt(pageKey, docIndex, updatedDoc);
                                                                }
                                                              }
                                                            : null,
                                                        onEdit: () {
                                                          Navigator.push(
                                                            context,
                                                            MaterialPageRoute(
                                                              builder: (context) => ImageEditorScreen(
                                                                pageIndex: pageKey,
                                                                documentIndex: docIndex
                                                              ),
                                                            ),
                                                          );
                                                        },
                                                        onDelete: () {
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
                                                                    ref.read(scannedDocumentsProvider.notifier).removeDocumentAt(pageKey, docIndex);
                                                                    if (selection.pageIndex == pageKey && selection.docIndex == docIndex) {
                                                                      _selectionNotifier.value = (pageIndex: null, docIndex: null);
                                                                    } else if (selection.pageIndex == pageKey && selection.docIndex != null && selection.docIndex! > docIndex) {
                                                                      _selectionNotifier.value = (pageIndex: selection.pageIndex, docIndex: selection.docIndex! - 1);
                                                                    }
                                                                    Navigator.pop(context);
                                                                  },
                                                                  child: const Text('حذف', style: TextStyle(color: Colors.red)),
                                                                ),
                                                              ],
                                                            ),
                                                          );
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
