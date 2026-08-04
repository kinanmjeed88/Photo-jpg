import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state.dart';
import '../services/scanner_service.dart';
import 'package:image_picker/image_picker.dart';
import '../services/pdf_service.dart';
import 'archive_screen.dart';
import 'image_editor_screen.dart';
import '../widgets/draggable_document.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  final ScannerService _scannerService = ScannerService();
  final PdfService _pdfService = PdfService();
  bool _isProcessing = false;
  int? _selectedDocIndex;

  Future<void> _scanImage(ImageSource source) async {
    final state = ref.read(appStateProvider);
    final file = await _scannerService.scanDocument(source: source);
    if (file != null) {
      setState(() {
        _isProcessing = true;
      });

      List<File> initialFiles = [file];

      // 1. First Segment if Smart Recognition is active
      if (state.smartRecognition) {
        initialFiles = await _scannerService.processSmartRecognition(file);
      }

      // 2. Loop over segments (or original)
      for (var processedFile in initialFiles) {
        // Removed the eager applyFilter call that breaks the editor colors

        if (state.smartRecognition) {
          final type = await _scannerService.classifyDocument(processedFile);
          ref.read(scannedDocumentsProvider.notifier).addDocument(ScannedDocument(file: processedFile, type: type));
        } else {
          ref.read(scannedDocumentsProvider.notifier).addDocument(ScannedDocument(file: processedFile));
        }
      }

      setState(() {
        _isProcessing = false;
      });
    }
  }

  void _showImageSourceOptions() {
    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return SafeArea(
          child: Wrap(
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.camera_alt),
                title: const Text('التقاط صورة'),
                onTap: () {
                  Navigator.of(context).pop();
                  _scanImage(ImageSource.camera);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('اختيار من المعرض'),
                onTap: () {
                  Navigator.of(context).pop();
                  _scanImage(ImageSource.gallery);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _generatePdf() async {
    final scannedDocuments = ref.read(scannedDocumentsProvider);
    if (scannedDocuments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الرجاء مسح مستمسك واحد على الأقل')),
      );
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    final state = ref.read(appStateProvider);

    try {
      await _pdfService.generatePdf(
        scannedDocuments: scannedDocuments,
        state: state,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تم إنشاء وحفظ الملف بنجاح')),
        );
        Navigator.pushReplacement(
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
    final scannedDocuments = ref.watch(scannedDocumentsProvider);

    // Calculate total pages needed based on highest pageIndex
    int totalPages = 1;
    if (scannedDocuments.isNotEmpty) {
      for (var doc in scannedDocuments) {
        if (doc.pageIndex >= totalPages) {
          totalPages = doc.pageIndex + 1;
        }
      }
    }

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
                  child: scannedDocuments.isEmpty
                      ? const Center(child: Text('لم يتم مسح أي مستمسكات بعد'))
                      : ListView.builder(
                          padding: const EdgeInsets.all(16),
                          itemCount: totalPages,
                          itemBuilder: (context, pageIndex) {
                            final docsOnPage = scannedDocuments.asMap().entries.where((e) => e.value.pageIndex == pageIndex).toList();

                            return Center(
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 24),
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

                                      // Sort docs so selected one is drawn last (on top)
                                      final sortedDocs = List.of(docsOnPage);
                                      sortedDocs.sort((a, b) {
                                        if (a.key == _selectedDocIndex) return 1;
                                        if (b.key == _selectedDocIndex) return -1;
                                        return 0;
                                      });

                                      return GestureDetector(
                                        behavior: HitTestBehavior.translucent,
                                        onTap: () {
                                          // Deselect if tapping empty space
                                          setState(() => _selectedDocIndex = null);
                                        },
                                        child: Stack(
                                          clipBehavior: Clip.none,
                                          children: [
                                            ...sortedDocs.map((entry) {
                                              final docIndex = entry.key;
                                              final doc = entry.value;

                                              return DraggableResizableDocument(
                                                key: ValueKey(doc.file.path),
                                                document: doc,
                                                index: docIndex,
                                                isSelected: _selectedDocIndex == docIndex,
                                                canvasWidth: canvasWidth,
                                                canvasHeight: canvasHeight,
                                                onTap: () {
                                                  setState(() => _selectedDocIndex = docIndex);
                                                },
                                                onEdit: () {
                                                  Navigator.push(
                                                    context,
                                                    MaterialPageRoute(
                                                      builder: (context) => ImageEditorScreen(documentIndex: docIndex),
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
                                                            ref.read(scannedDocumentsProvider.notifier).removeDocumentAt(docIndex);
                                                            if (_selectedDocIndex == docIndex) {
                                                              setState(() => _selectedDocIndex = null);
                                                            }
                                                            Navigator.pop(context);
                                                          },
                                                          child: const Text('حذف', style: TextStyle(color: Colors.red)),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                                onLayoutUpdate: (index, dx, dy, width, height, newPageIndex) {
                                                  ref.read(scannedDocumentsProvider.notifier).updateDocumentLayout(
                                                    index,
                                                    dx: dx,
                                                    dy: dy,
                                                    width: width,
                                                    height: height,
                                                    pageIndex: newPageIndex,
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
                          onPressed: scannedDocuments.isEmpty ? null : _generatePdf,
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
