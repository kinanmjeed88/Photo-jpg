import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../providers/app_state.dart';
import 'dart:math' as math;
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
          final docType = await _scannerService.classifyDocument(processedFile);

          List<File> finalFiles = [processedFile];

          if (smartRecog) {
            finalFiles = await _scannerService.processSmartRecognition(processedFile);
            if (finalFiles.isEmpty) {
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

          for (var f in finalFiles) {
            final decoded = await decodeImageFromList(await f.readAsBytes());

            DocumentType specificType = docType;
            if (f.path.endsWith('_A4.jpg')) {
              specificType = DocumentType.a4Document;
            }

            // DO NOT hardcode width here. Pass the raw intrinsic dimensions to state.
            // The ScannedDocumentsNotifier will calculate the mathematical width/height.
            ref.read(scannedDocumentsProvider.notifier).addDocument(ScannedDocument(
              file: f,
              type: specificType,
              originalWidth: decoded.width.toDouble(),
              originalHeight: decoded.height.toDouble(),
            ), ref.read(appStateProvider));
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
                                              child: DragTarget<Map<String, dynamic>>(
                                                onAcceptWithDetails: (details) {
                                                  // Because DragTarget is inside FittedBox and SizedBox,
                                                  // the render box's local coordinate system is exactly
                                                  // the virtual canvas coordinate space (400 x 565.6).
                                                  final RenderBox renderBox = context.findRenderObject()! as RenderBox;
                                                  final localOffset = renderBox.globalToLocal(details.offset);

                                                  final data = details.data as Map<String, dynamic>;
                                                  final doc = data['document'] as ScannedDocument;
                                                  final sourcePageIndex = data['pageIndex'] as int;
                                                  // We do not rely on sourceDocIndex directly for update/remove because
                                                  // the Z-index might have changed while dragging (e.g. moveToTop was called).
                                                  // Instead, we find the real index of the document in the source page based on its file path.

                                                  // With custom top-left dragAnchorStrategy, localOffset maps 1:1
                                                  // to the precise drop coordinate.
                                                  double virtualDx = localOffset.dx;
                                                  double virtualDy = localOffset.dy;

                                                  virtualDx = math.max(0.0, math.min(virtualDx, AppConstants.kVirtualCanvasWidth - doc.width));
                                                  virtualDy = math.max(0.0, math.min(virtualDy, AppConstants.kVirtualCanvasHeight - doc.height));

                                                  final newDoc = doc.copyWith(dx: virtualDx, dy: virtualDy);

                                                  final currentState = ref.read(scannedDocumentsProvider);
                                                  final sourceDocs = currentState[sourcePageIndex] ?? [];

                                                  // Find actual index to prevent Z-index corruption
                                                  int actualDocIndex = sourceDocs.indexWhere((d) => d.file.path == doc.file.path);

                                                  if (actualDocIndex == -1) {
                                                      // Fallback to the provided index if for some reason it's not found
                                                      actualDocIndex = data['docIndex'] as int;
                                                  }

                                                  if (sourcePageIndex == pageKey) {
                                                    // Atomic update to avoid state stomping
                                                    ref.read(scannedDocumentsProvider.notifier).updateAndMoveToTop(sourcePageIndex, actualDocIndex, newDoc);

                                                    final currentDocsCount = ref.read(scannedDocumentsProvider)[pageKey]?.length ?? 0;
                                                    if (currentDocsCount > 0) {
                                                      _selectionNotifier.value = (pageIndex: pageKey, docIndex: currentDocsCount - 1);
                                                    }
                                                  } else {
                                                    ref.read(scannedDocumentsProvider.notifier).removeDocumentAt(sourcePageIndex, actualDocIndex);
                                                    final updatedState = ref.read(scannedDocumentsProvider);
                                                    final targetPageDocs = updatedState[pageKey] ?? [];

                                                    ref.read(scannedDocumentsProvider.notifier).setRawState( {
                                                      ...updatedState,
                                                      pageKey: [...targetPageDocs, newDoc],
                                                    });

                                                    _selectionNotifier.value = (pageIndex: pageKey, docIndex: targetPageDocs.length);
                                                  }
                                                },
                                                builder: (context, candidateData, rejectedData) {
                                                  return GestureDetector(
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
                                                          );
                                                        }).toList(),
                                                      ],
                                                    ),
                                                  );
                                                },
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
                        child: ElevatedButton.icon(
                          onPressed: _showImageSourceOptions,
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('إضافة صورة'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: pages.isEmpty ? null : _generatePdf,
                          icon: const Icon(Icons.picture_as_pdf),
                          label: const Text('إنشاء PDF'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
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
