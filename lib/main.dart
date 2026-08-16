import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'screens/settings_screen.dart';
import 'services/temporary_image_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(TemporaryImageStore.cleanupStale());
  runApp(const ProviderScope(child: DocScannerApp()));
}

class DocScannerApp extends StatefulWidget {
  const DocScannerApp({super.key});

  @override
  State<DocScannerApp> createState() => _DocScannerAppState();
}

class _DocScannerAppState extends State<DocScannerApp> {
  final LocalAuthentication auth = LocalAuthentication();
  bool _isAuthenticated = false;
  bool _isAuthenticating = false;

  @override
  void initState() {
    super.initState();
    _authenticate();
  }

  Future<void> _authenticate() async {
    bool authenticated = false;
    try {
      setState(() {
        _isAuthenticating = true;
      });
      authenticated = await auth.authenticate(
        localizedReason: 'يرجى المصادقة للوصول إلى المستمسكات',
        options: AuthenticationOptions(stickyAuth: true, biometricOnly: false),
      );
      setState(() {
        _isAuthenticating = false;
        _isAuthenticated = authenticated;
      });
    } catch (e) {
      setState(() {
        _isAuthenticating = false;
        _isAuthenticated = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ماسح المستمسكات',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('ar')],
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F172A), // Navy/Dark Blue
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF4F46E5), // Indigo
          secondary: Color(0xFFF59E0B), // Gold/Yellow
          surface: Color(0xFF1E293B),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1E293B),
          elevation: 0,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF4F46E5), // Indigo main buttons
            foregroundColor: Colors.white,
          ),
        ),
        useMaterial3: true,
      ),
      home: _isAuthenticating
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _isAuthenticated
          ? const SettingsScreen()
          : Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'المصادقة مطلوبة لحماية مستمسكاتك',
                      style: TextStyle(fontSize: 18),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton(
                      onPressed: _authenticate,
                      child: const Text('إعادة المحاولة'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
