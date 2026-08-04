import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state.dart';
import '../services/scanner_service.dart';
import 'package:image_picker/image_picker.dart';
import '../services/pdf_service.dart';
import 'archive_screen.dart';
import 'image_editor_screen.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  final ScannerService _scannerService = ScannerService();
  final PdfService _pdfService = PdfService();
  bool _isProcessing = false;

  Future<void> _scanImage(ImageSource source) async {
    final state = ref.read(appStateProvider);
    final file = await _scannerService.scanDocument(source: source);
    if (file != null) {
      setState(() {
        _isProcessing = true;
      });

      File processedFile = file;

      if (state.autoDeskew) {
        processedFile = await _scannerService.processAutoDeskew(processedFile);
      }

      final filteredFile = await _scannerService.applyFilter(processedFile, true);
      processedFile = filteredFile ?? processedFile;

      if (state.smartRecognition) {
        final croppedFiles = await _scannerService.processSmartRecognition(processedFile);

        for (var croppedFile in croppedFiles) {
          final type = await _scannerService.classifyDocument(croppedFile);
          ref.read(scannedDocumentsProvider.notifier).addDocument(ScannedDocument(file: croppedFile, type: type));
        }
      } else {
        ref.read(scannedDocumentsProvider.notifier).addDocument(ScannedDocument(file: processedFile));
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('مسح المستمسكات'),
      ),
      body: _isProcessing
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: scannedDocuments.isEmpty
                      ? const Center(child: Text('لم يتم مسح أي مستمسكات بعد'))
                      : GridView.builder(
                          padding: const EdgeInsets.all(8),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount: scannedDocuments.length,
                          itemBuilder: (context, index) {
                            final doc = scannedDocuments[index];
                            return GestureDetector(
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => ImageEditorScreen(documentIndex: index),
                                  ),
                                );
                              },
                              child: Stack(
                                children: [
                                  Image.file(doc.file, fit: BoxFit.cover, width: double.infinity, height: double.infinity),
                                  Positioned(
                                    top: 0,
                                    right: 0,
                                    child: IconButton(
                                      icon: const Icon(Icons.delete, color: Colors.red),
                                      onPressed: () {
                                        ref.read(scannedDocumentsProvider.notifier).removeDocumentAt(index);
                                      },
                                    ),
                                  ),
                                  if (doc.type != DocumentType.unknown)
                                    Positioned(
                                      bottom: 0,
                                      left: 0,
                                      right: 0,
                                      child: Container(
                                        color: Colors.black54,
                                        padding: const EdgeInsets.symmetric(vertical: 4),
                                        child: Text(
                                          doc.type.name, // Format this properly later
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(color: Colors.white, fontSize: 12),
                                        ),
                                      ),
                                    ),
                                ],
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
