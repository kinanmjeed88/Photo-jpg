import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/app_state.dart';
import 'archive_screen.dart';
import 'scanner_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appStateProvider);
    final notifier = ref.read(appStateProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('إعدادات المستمسك'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder),
            tooltip: 'الأرشيف',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ArchiveScreen()),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'المستمسكات المطلوبة:',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFFF59E0B),
              ),
            ),
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
            const Text(
              'طريقة العرض:',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFFF59E0B),
              ),
            ),
            RadioListTile<DisplayMethod>(
              title: const Text('ورقة واحدة - وجه وظهر في نفس الصفحة'),
              value: DisplayMethod.onePage,
              groupValue: state.displayMethod,
              onChanged: (val) => notifier.updateDisplayMethod(val!),
              activeColor: const Color(0xFFF59E0B),
            ),
            RadioListTile<DisplayMethod>(
              title: const Text('ورقتان - للطباعة وجهين'),
              value: DisplayMethod.twoPages,
              groupValue: state.displayMethod,
              onChanged: (val) => notifier.updateDisplayMethod(val!),
              activeColor: const Color(0xFFF59E0B),
            ),
            RadioListTile<DisplayMethod>(
              title: const Text('وجه فقط'),
              value: DisplayMethod.frontOnly,
              groupValue: state.displayMethod,
              onChanged: (val) => notifier.updateDisplayMethod(val!),
              activeColor: const Color(0xFFF59E0B),
            ),
            const Divider(),
            const Text(
              'ميزات الذكاء الاصطناعي:',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFFF59E0B),
              ),
            ),
            SwitchListTile(
              title: const Text('التعرف الذكي (قص وتصنيف تلقائي)'),
              value: state.smartRecognition,
              onChanged: notifier.toggleSmartRecognition,
              activeColor: const Color(0xFFF59E0B),
            ),
            const Divider(),
            const Text(
              'إخراج الملف:',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFFF59E0B),
              ),
            ),
            SwitchListTile(
              title: const Text('إضافة إطار حول الصور'),
              value: state.addFrame,
              onChanged: notifier.toggleAddFrame,
              activeColor: const Color(0xFFF59E0B),
            ),
            const SizedBox(height: 10),
            TextField(
              decoration: const InputDecoration(
                labelText: 'اسم الملف',
                hintText: 'مستمسكاتي',
                border: OutlineInputBorder(),
              ),
              onChanged: (val) {
                notifier.updateFileName(val.isEmpty ? 'مستمسكاتي' : val);
              },
            ),
            const SizedBox(height: 20),
            Center(
              child: Text(
                state.hasAtLeastOneDocument
                    ? ''
                    : 'الحالة: لازم تختار مستمسك واحد على الأقل',
                style: const TextStyle(color: Colors.redAccent, fontSize: 16),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: state.hasAtLeastOneDocument
                    ? () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const ScannerScreen(),
                          ),
                        );
                      }
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
}
