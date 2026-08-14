import 'dart:io';

import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key});

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  List<File> _files = <File>[];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  Future<Directory> _archiveDirectory() => getApplicationDocumentsDirectory();

  Future<bool> _isManagedPdf(File file) async {
    final root = path.normalize((await _archiveDirectory()).absolute.path);
    final parent = path.normalize(file.parent.absolute.path);
    return path.equals(root, parent) &&
        path.extension(file.path).toLowerCase() == '.pdf';
  }

  Future<void> _loadFiles() async {
    try {
      final directory = await _archiveDirectory();
      final files = <File>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File &&
            path.extension(entity.path).toLowerCase() == '.pdf' &&
            await _isManagedPdf(entity)) {
          files.add(entity);
        }
      }
      files.sort(
        (first, second) =>
            second.lastModifiedSync().compareTo(first.lastModifiedSync()),
      );
      if (mounted) {
        setState(() {
          _files = files;
          _isLoading = false;
        });
      }
    } on FileSystemException {
      if (mounted) {
        setState(() => _isLoading = false);
        _showMessage('تعذر قراءة الأرشيف.');
      }
    }
  }

  Future<void> _openFile(File file) async {
    if (!await _isManagedPdf(file)) return;
    await OpenFilex.open(file.path);
  }

  Future<void> _shareFile(File file) async {
    if (!await _isManagedPdf(file)) return;
    await SharePlus.instance.share(
      ShareParams(files: <XFile>[XFile(file.path)], text: 'مشاركة المستمسكات'),
    );
  }

  Future<void> _deleteFile(File file) async {
    if (!await _isManagedPdf(file)) {
      _showMessage('هذا الملف خارج نطاق الأرشيف.');
      return;
    }
    try {
      await file.delete();
      await _loadFiles();
    } on FileSystemException {
      if (mounted) _showMessage('تعذر حذف الملف.');
    }
  }

  String? _sanitizeBaseName(String input) {
    final normalized = input.replaceAll('\\', '/').trim();
    if (normalized.isEmpty || normalized.contains('..')) return null;
    var base = path
        .basenameWithoutExtension(normalized)
        .replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    base = base.replaceAll(RegExp(r'^\.+|\.+$'), '');
    if (base.isEmpty || base == '.' || base == '..') return null;
    return base.substring(0, base.length > 80 ? 80 : base.length);
  }

  Future<void> _renameFile(File file, String requestedName) async {
    if (!await _isManagedPdf(file)) {
      _showMessage('لا يمكن إعادة تسمية ملف خارج الأرشيف.');
      return;
    }
    final baseName = _sanitizeBaseName(requestedName);
    if (baseName == null) {
      _showMessage('اسم الملف غير صالح.');
      return;
    }
    final directory = await _archiveDirectory();
    final target = File(path.join(directory.path, '$baseName.pdf'));
    if (!await _isManagedPdf(target)) {
      _showMessage('مسار الاسم الجديد غير آمن.');
      return;
    }
    if (path.equals(file.absolute.path, target.absolute.path)) return;
    if (await target.exists()) {
      _showMessage('يوجد ملف بالاسم نفسه.');
      return;
    }
    try {
      await file.rename(target.path);
      await _loadFiles();
    } on FileSystemException {
      if (mounted) _showMessage('تعذرت إعادة التسمية.');
    }
  }

  Future<void> _showDeleteConfirmationDialog(File file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: const Text('هل أنت متأكد من أنك تريد حذف هذا الملف؟'),
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
    if (confirmed == true && mounted) await _deleteFile(file);
  }

  Future<void> _showRenameDialog(File file) async {
    final controller = TextEditingController(
      text: path.basenameWithoutExtension(file.path),
    );
    final requestedName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إعادة تسمية الملف'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'الاسم الجديد'),
          onSubmitted: Navigator.of(context).pop,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (requestedName != null && mounted) {
      await _renameFile(file, requestedName);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('أرشيف المستمسكات')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
          ? const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(Icons.folder_open, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'لا توجد ملفات محفوظة',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _files.length,
              itemBuilder: (context, index) {
                final file = _files[index];
                return ListTile(
                  leading: const Icon(
                    Icons.picture_as_pdf,
                    color: Colors.redAccent,
                  ),
                  title: Text(path.basename(file.path)),
                  onTap: () => _openFile(file),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        icon: const Icon(Icons.share, color: Colors.blue),
                        tooltip: 'مشاركة',
                        onPressed: () => _shareFile(file),
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
