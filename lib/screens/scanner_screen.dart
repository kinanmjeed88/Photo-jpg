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

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  final ScannerService _scannerService = ScannerService();
  final PdfService _pdfService = PdfService();

  bool _isProcessing = false;
  int? _selectedPageIndex;
  int? _selectedDocIndex;

  double _lastKnownCanvasWidth = 380.0;
  double _lastKnownCanvasHeight = 537.32;

  Future<void> _scanDocument(ImageSource source) async {
    try {
      // Pick multiple images if gallery
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
          // Document type classification
          final docType = await _scannerService.classifyDocument(processedFile);

          List<File> finalFiles = [processedFile];

          if (smartRecog) {
            finalFiles = await _scannerService.processSmartRecognition(processedFile);
            if (finalFiles.isEmpty) {
              // Smart Manual Cropper Fallback
              final result = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => MultiCropScreen(imageFile: processedFile),
                ),
              );
              if (result != null && result is List<File>) {
                finalFiles = result;
              } else {
                finalFiles = [processedFile]; // Or continue if we don't want to add it
              }
            }
          }

          for (var f in finalFiles) {
            final decoded = await decodeImageFromList(await f.readAsBytes());
            double aspect = decoded.width / decoded.height;
            double docWidth = 300;
            double docHeight = docWidth / aspect;

            DocumentType specificType = docType;
            if (f.path.endsWith('_A4.jpg')) {
              specificType = DocumentType.a4Document;
            }

            ref.read(scannedDocumentsProvider.notifier).addDocument(ScannedDocument(
              file: f,
              type: specificType,
              width: docWidth,
              height: docHeight,
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
      backgroundColor: const Color(0xFFF1F5F9), // Light background to contrast A4 canvas
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
                                  aspectRatio: 1 / 1.414, // A4 format
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final canvasWidth = constraints.maxWidth;
                                      final canvasHeight = constraints.maxHeight;

                                      // Update tracked dimensions
                                      WidgetsBinding.instance.addPostFrameCallback((_) {
                                        if (mounted && (_lastKnownCanvasWidth != canvasWidth || _lastKnownCanvasHeight != canvasHeight)) {
                                          _lastKnownCanvasWidth = canvasWidth;
                                          _lastKnownCanvasHeight = canvasHeight;
                                        }
                                      });

                                      // Sort docs so selected one is drawn last (on top)
                                      final sortedDocs = List.of(docsOnPage);
                                      sortedDocs.sort((a, b) {
                                        bool aSelected = (_selectedPageIndex == pageKey && _selectedDocIndex == a.key);
                                        bool bSelected = (_selectedPageIndex == pageKey && _selectedDocIndex == b.key);
                                        if (aSelected) return 1;
                                        if (bSelected) return -1;
                                        return 0;
                                      });

                                      return DragTarget<Map<String, dynamic>>(

                                        onAcceptWithDetails: (details) {
                                          final RenderBox renderBox = context.findRenderObject() as RenderBox;
                                          final localOffset = renderBox.globalToLocal(details.offset);

                                          // The virtual canvas represents a fixed physical A4 aspect ratio
                                          // but scales down to fit the device screen. We need to calculate
                                          // exactly how the 400x565.6 box is scaled inside its parent constraints.

                                          // Assuming FittedBox fits perfectly by width or height
                                          double scaleX = 400.0 / renderBox.size.width;
                                          double scaleY = 565.6 / renderBox.size.height;

                                          final data = details.data as Map<String, dynamic>;
                                          final doc = data['document'] as ScannedDocument;
                                          final sourcePageIndex = data['pageIndex'] as int;
                                          final sourceDocIndex = data['docIndex'] as int;

                                          // Compensate for the 12px drag padding offset in the Draggable
                                          // Because of custom dragAnchorStrategy, localOffset is exactly the top-left corner of the container (not the pointer).
                                          // The container has 12px padding left/top for the shadow/border.
                                          double virtualDx = (localOffset.dx * scaleX) + 12.0;
                                          double virtualDy = (localOffset.dy * scaleY) + 12.0;

                                          // Local Strict bounds clamping for drag
                                          virtualDx = math.max(0.0, math.min(virtualDx, 400.0 - doc.width));
                                          virtualDy = math.max(0.0, math.min(virtualDy, 565.6 - doc.height));

                                          final newDoc = doc.copyWith(dx: virtualDx, dy: virtualDy);

                                          // Update State
                                          if (sourcePageIndex == pageKey) {
                                            ref.read(scannedDocumentsProvider.notifier).updateDocumentAt(sourcePageIndex, sourceDocIndex, newDoc);
                                            ref.read(scannedDocumentsProvider.notifier).moveDocumentToTop(sourcePageIndex, sourceDocIndex);

                                            // Select the dropped document (it's now at the end of the list)
                                            final currentDocsCount = ref.read(scannedDocumentsProvider)[pageKey]?.length ?? 0;
                                            if (currentDocsCount > 0) {
                                                setState(() {
                                                    _selectedPageIndex = pageKey;
                                                    _selectedDocIndex = currentDocsCount - 1;
                                                });
                                            }
                                          } else {
                                            ref.read(scannedDocumentsProvider.notifier).removeDocumentAt(sourcePageIndex, sourceDocIndex);
                                            // Force add the new document directly into the target page
                                            final currentState = ref.read(scannedDocumentsProvider);
                                            final targetPageDocs = currentState[pageKey] ?? [];

                                            ref.read(scannedDocumentsProvider.notifier).state = {
                                              ...currentState,
                                              pageKey: [...targetPageDocs, newDoc],
                                            };

                                            setState(() {
                                                _selectedPageIndex = pageKey;
                                                _selectedDocIndex = targetPageDocs.length;
                                            });
                                          }
                                        },

                                        builder: (context, candidateData, rejectedData) {
                                          return GestureDetector(
                                            behavior: HitTestBehavior.translucent,
                                            onTap: () {
                                              // Deselect if tapping empty space
                                              setState(() {
                                                _selectedPageIndex = null;
                                                _selectedDocIndex = null;
                                              });
                                            },
                                            child: FittedBox(
                                              fit: BoxFit.contain,
                                              child: SizedBox(
                                                width: 400.0,
                                                height: 565.6,
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
                                                    isSelected: _selectedPageIndex == pageKey && _selectedDocIndex == docIndex,
                                                    addFrame: appState.addFrame,
                                                    canvasWidth: 400.0,
                                                    canvasHeight: 565.6,
                                                    canvasScale: constraints.maxWidth / 400.0,
                                                onDragStarted: () {
                                                  if (_selectedPageIndex != pageKey || _selectedDocIndex != docIndex) {
                                                    setState(() {
                                                      _selectedPageIndex = pageKey;
                                                      _selectedDocIndex = docIndex;
                                                    });
                                                  }
                                                },
                                                onTap: () {
                                                  if (_selectedPageIndex != pageKey || _selectedDocIndex != docIndex) {
                                                    ref.read(scannedDocumentsProvider.notifier).moveDocumentToTop(pageKey, docIndex);
                                                    final currentDocsCount = ref.read(scannedDocumentsProvider)[pageKey]?.length ?? 0;
                                                    setState(() {
                                                      _selectedPageIndex = pageKey;
                                                      _selectedDocIndex = currentDocsCount > 0 ? currentDocsCount - 1 : docIndex;
                                                    });
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
                                                            if (_selectedPageIndex == pageKey && _selectedDocIndex == docIndex) {
                                                              setState(() {
                                                                _selectedPageIndex = null;
                                                                _selectedDocIndex = null;
                                                              });
                                                            } else if (_selectedPageIndex == pageKey && _selectedDocIndex != null && _selectedDocIndex! > docIndex) {
                                                              setState(() {
                                                                _selectedDocIndex = _selectedDocIndex! - 1;
                                                              });
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
