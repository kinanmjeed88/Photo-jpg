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
      final List<File> pickedFiles = [];
      if (source == ImageSource.gallery) {
        final List<File>? files = await _scannerService.scanMultipleDocuments();
        if (files != null && files.isNotEmpty) {
          pickedFiles.addAll(files);
        }
      } else {
        final File? file = await _scannerService.scanDocument(source: source);
        if (file != null) {
          pickedFiles.add(file);
        }
      }

      if (pickedFiles.isEmpty) return;

      setState(() {
        _isProcessing = true;
      });

      if (mounted) {
        final bool smartRecog = ref.read(appStateProvider).smartRecognition;

        for (var processedFile in pickedFiles) {
          await _scannerService.classifyDocument(processedFile);

          List<File> finalFiles = [processedFile];

          if (smartRecog) {
            finalFiles = await _scannerService.processSmartRecognition(processedFile);
            if (finalFiles.isEmpty) {
              if (!mounted) return;
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => MultiCropScreen(imageFile: processedFile),
                ),
              );
              if (result != null && result is List<File>) {
                finalFiles = result;
              } else {
                finalFiles = [processedFile];
              }
            }
          }


          final currentState = ref.read(scannedDocumentsProvider);
          int currentPage = currentState.isEmpty ? 0 : currentState.keys.reduce((a, b) => a > b ? a : b);
          final appState = ref.read(appStateProvider);

          final result = await ref.read(scannedDocumentsProvider.notifier).batchAddDocuments(finalFiles, appState, currentPage);

          if (result.overflowFiles.isNotEmpty && mounted) {
            bool? createNewPage = await showDialog<bool>(
              context: context,
              builder: (BuildContext context) {
                return AlertDialog(
                  title: const Text('الصفحة ممتلئة'),
                  content: Text('تم إضافة ${result.addedDocuments.length} مستندات بنجاح. الصفحة الحالية لا تتسع لـ ${result.overflowFiles.length} مستندات المتبقية. هل تريد إنشاء صفحة جديدة للمستندات المتبقية؟'),
                  actions: <Widget>[
                    TextButton(
                      child: const Text('إلغاء'),
                      onPressed: () {
                        debugPrint("User cancelled overflow.");
                        Navigator.of(context).pop(false);
                      },
                    ),
                    TextButton(
                      child: const Text('إنشاء صفحة جديدة'),
                      onPressed: () {
                        debugPrint("User chose to create a new page for overflow.");
                        Navigator.of(context).pop(true);
                      },
                    ),
                  ],
                );
              },
            );

            if (createNewPage == true) {
              await ref.read(scannedDocumentsProvider.notifier).batchAddDocuments(result.overflowFiles, appState, currentPage + 1);
            }
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
        uiCanvasWidth: _lastKnownCanvasWidth,
        uiCanvasHeight: _lastKnownCanvasHeight,
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
                                                        onLayoutUpdate: (pIndex, dIndex, dx, dy, width, height) {
                                                          ref.read(scannedDocumentsProvider.notifier).updateDocumentLayout(
                                                            pIndex,
                                                            dIndex,
                                                            dx: dx,
                                                            dy: dy,
                                                            width: width,
                                                            height: height,
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
