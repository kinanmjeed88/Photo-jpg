import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  List<FileSystemEntity> _files = [];

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<void> _loadFiles() async {
    final dir = await getApplicationDocumentsDirectory();
    final files = dir.listSync().where((item) => item.path.endsWith('.pdf')).toList();
    setState(() {
      _files = files;
    });
  }

  Future<void> _openFile(String path) async {
    await OpenFilex.open(path);
  }

  Future<void> _shareFile(String path) async {
    await Share.shareXFiles([XFile(path)], text: 'مشاركة المستمسكات');
  }

  Future<void> _deleteFile(File file) async {
    await file.delete();
    _loadFiles();
  }

  void _showDeleteConfirmationDialog(File file) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('تأكيد الحذف'),
          content: const Text('هل أنت متأكد من أنك تريد حذف هذا الملف؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () {
                _deleteFile(file);
                Navigator.pop(context);
              },
              child: const Text('حذف', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _renameFile(File file, String newName) async {
    final dir = file.parent.path;
    final newPath = '$dir/$newName.pdf';
    await file.rename(newPath);
    _loadFiles();
  }

  void _showRenameDialog(File file) {
    String newName = file.uri.pathSegments.last.replaceAll('.pdf', '');
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('إعادة تسمية الملف'),
          content: TextField(
            onChanged: (val) => newName = val,
            controller: TextEditingController(text: newName),
            decoration: const InputDecoration(hintText: 'الاسم الجديد'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            TextButton(
              onPressed: () {
                _renameFile(file, newName);
                Navigator.pop(context);
              },
              child: const Text('حفظ'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('أرشيف المستمسكات'),
      ),
      body: _files.isEmpty
          ? const Center(child: Text('لا توجد ملفات محفوظة'))
          : ListView.builder(
              itemCount: _files.length,
              itemBuilder: (context, index) {
                final file = _files[index] as File;
                final fileName = file.uri.pathSegments.last;

                return ListTile(
                  leading: const Icon(Icons.picture_as_pdf, color: Colors.redAccent),
                  title: Text(fileName),
                  onTap: () => _openFile(file.path),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.share, color: Colors.blue),
                        tooltip: 'مشاركة',
                        onPressed: () => _shareFile(file.path),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit, color: Colors.orange),
                        tooltip: 'إعادة تسمية',
                        onPressed: () => _showRenameDialog(file),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        tooltip: 'حذف',
                        onPressed: () => _showDeleteConfirmationDialog(file),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
