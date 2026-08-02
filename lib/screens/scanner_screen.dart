import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state.dart';
import '../services/scanner_service.dart';
import '../services/pdf_service.dart';
import 'archive_screen.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  const ScannerScreen({super.key});

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen> {
  final ScannerService _scannerService = ScannerService();
  final PdfService _pdfService = PdfService();
  final List<File> _scannedImages = [];
  bool _isProcessing = false;

  Future<void> _scanImage() async {
    final file = await _scannerService.scanDocument();
    if (file != null) {
      setState(() {
        _isProcessing = true;
      });
      // Optionally apply filter here
      final filteredFile = await _scannerService.applyFilter(file, true);
      setState(() {
        if (filteredFile != null) {
          _scannedImages.add(filteredFile);
        } else {
          _scannedImages.add(file);
        }
        _isProcessing = false;
      });
    }
  }

  Future<void> _generatePdf() async {
    if (_scannedImages.isEmpty) {
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
        images: _scannedImages,
        displayMethod: state.displayMethod,
        addFrame: state.addFrame,
        fileName: state.fileName,
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('مسح المستمسكات'),
      ),
      body: _isProcessing
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: _scannedImages.isEmpty
                      ? const Center(child: Text('لم يتم مسح أي مستمسكات بعد'))
                      : GridView.builder(
                          padding: const EdgeInsets.all(8),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                          ),
                          itemCount: _scannedImages.length,
                          itemBuilder: (context, index) {
                            return Stack(
                              children: [
                                Image.file(_scannedImages[index], fit: BoxFit.cover, width: double.infinity, height: double.infinity),
                                Positioned(
                                  top: 0,
                                  right: 0,
                                  child: IconButton(
                                    icon: const Icon(Icons.delete, color: Colors.red),
                                    onPressed: () {
                                      setState(() {
                                        _scannedImages.removeAt(index);
                                      });
                                    },
                                  ),
                                ),
                              ],
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
                          onPressed: _scanImage,
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('إضافة صورة'),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _scannedImages.isEmpty ? null : _generatePdf,
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
