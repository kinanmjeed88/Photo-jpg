import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_state.dart';
import 'archive_screen.dart';
import 'scanner_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const _accent = Color(0xFFF59E0B);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appStateProvider);
    final notifier = ref.read(appStateProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('إعدادات المستمسك'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.folder),
            tooltip: 'الأرشيف',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (context) => const ArchiveScreen(),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _sectionTitle('المستمسكات المطلوبة:'),
            CheckboxListTile(
              title: const Text('البطاقة الموحدة'),
              value: state.hasNationalId,
              onChanged: notifier.toggleNationalId,
              activeColor: const Color(0xFF4F46E5),
            ),
            CheckboxListTile(
              title: const Text('بطاقة السكن'),
              value: state.hasHousingCard,
              onChanged: notifier.toggleHousingCard,
              activeColor: const Color(0xFF4F46E5),
            ),
            CheckboxListTile(
              title: const Text('البطاقة التموينية'),
              value: state.hasRationCard,
              onChanged: notifier.toggleRationCard,
              activeColor: const Color(0xFF4F46E5),
            ),
            CheckboxListTile(
              title: const Text('جواز السفر'),
              value: state.hasPassport,
              onChanged: notifier.togglePassport,
              activeColor: const Color(0xFF4F46E5),
            ),
            const Divider(),
            _sectionTitle('طريقة العرض:'),
            RadioGroup<DisplayMethod>(
              groupValue: state.displayMethod,
              onChanged: (value) {
                if (value != null) notifier.updateDisplayMethod(value);
              },
              child: const Column(
                children: <Widget>[
                  RadioListTile<DisplayMethod>(
                    title: Text('ورقة واحدة - وجه وظهر في نفس الصفحة'),
                    value: DisplayMethod.onePage,
                    activeColor: _accent,
                  ),
                  RadioListTile<DisplayMethod>(
                    title: Text('ورقتان - للطباعة وجهين'),
                    value: DisplayMethod.twoPages,
                    activeColor: _accent,
                  ),
                  RadioListTile<DisplayMethod>(
                    title: Text('وجه فقط'),
                    value: DisplayMethod.frontOnly,
                    activeColor: _accent,
                  ),
                ],
              ),
            ),
            const Divider(),
            _sectionTitle('ميزات الذكاء الاصطناعي:'),
            SwitchListTile(
              title: const Text('التعرف الذكي (قص وتصنيف تلقائي)'),
              value: state.smartRecognition,
              onChanged: notifier.toggleSmartRecognition,
              activeThumbColor: _accent,
            ),
            const Divider(),
            _sectionTitle('إخراج الملف:'),
            SwitchListTile(
              title: const Text('إضافة إطار حول الصور'),
              value: state.addFrame,
              onChanged: notifier.toggleAddFrame,
              activeThumbColor: _accent,
            ),
            const SizedBox(height: 10),
            TextField(
              decoration: const InputDecoration(
                labelText: 'اسم الملف',
                hintText: 'مستمسكاتي',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => notifier.updateFileName(
                value.trim().isEmpty ? 'مستمسكاتي' : value.trim(),
              ),
            ),
            const SizedBox(height: 20),
            if (!state.hasAtLeastOneDocument)
              const Center(
                child: Text(
                  'الحالة: لازم تختار مستمسك واحد على الأقل',
                  style: TextStyle(color: Colors.redAccent, fontSize: 16),
                ),
              ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: state.hasAtLeastOneDocument
                    ? () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (context) => const ScannerScreen(),
                        ),
                      )
                    : null,
                child: const Text(
                  'متابعة إلى المسح',
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
        color: _accent,
      ),
    );
  }
}
