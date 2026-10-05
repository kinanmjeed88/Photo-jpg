import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import 'providers/app_state.dart';
import 'screens/settings_screen.dart';
import 'services/temporary_image_store.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Stale work files are groomed exactly once, at start-up, where no document
  // can be in use. Doing it before every scan used to delete images that were
  // still placed on the canvas.
  unawaited(TemporaryImageStore.cleanupStale());
  runApp(const ProviderScope(child: DocScannerApp()));
}

/// Result of the start-up authentication attempt.
enum _AccessStatus {
  /// A biometric or device-credential prompt is in progress.
  checking,

  /// The owner proved their identity with the device lock.
  authenticated,

  /// A device lock exists but the owner did not pass it. The gate stays closed
  /// and only the retry action is offered, exactly like the original flow.
  lockedOut,

  /// The device has no lock configured at all, so there is nothing to verify.
  /// Blocking here would lock the owner out of their own documents forever;
  /// the gate states the situation and lets them continue deliberately.
  noDeviceLock,
}

class DocScannerApp extends ConsumerStatefulWidget {
  const DocScannerApp({super.key});

  @override
  ConsumerState<DocScannerApp> createState() => _DocScannerAppState();
}

class _DocScannerAppState extends ConsumerState<DocScannerApp>
    with WidgetsBindingObserver {
  final LocalAuthentication _auth = LocalAuthentication();
  _AccessStatus _status = _AccessStatus.checking;
  bool _isAuthenticating = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(ref.read(appStateProvider.notifier).restorePersistedState());
    // Deferred to the first frame: the initial state already displays the
    // progress indicator, and no rebuild is needed during mount.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_authenticate());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist pending preference changes as soon as the app leaves the
    // foreground: the process may be killed without another chance to write.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(ref.read(appStateProvider.notifier).flushPersistedState());
    }
  }

  Future<void> _authenticate() async {
    if (!mounted || _isAuthenticating) return;
    setState(() {
      _isAuthenticating = true;
      _status = _AccessStatus.checking;
      _message = null;
    });
    try {
      if (!await _auth.isDeviceSupported()) {
        _finish(
          _AccessStatus.noDeviceLock,
          'لا يوجد قفل شاشة مُفعَّل على هذا الجهاز.',
        );
        return;
      }
      final authenticated = await _auth.authenticate(
        localizedReason: 'يرجى المصادقة للوصول إلى المستمسكات',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
      if (authenticated) {
        _finish(_AccessStatus.authenticated, null);
      } else {
        // Dismissing the prompt keeps the gate closed, as before.
        _finish(_AccessStatus.lockedOut, 'لم تُكتمل المصادقة.');
      }
    } on PlatformException catch (error) {
      // A device with a lock that cannot authenticate (no enrolment, lockout,
      // missing activity) is reported precisely, but never unlocks the app.
      _finish(_AccessStatus.lockedOut, _authErrorMessage(error));
    } catch (_) {
      _finish(_AccessStatus.lockedOut, 'تعذر تشغيل المصادقة على هذا الجهاز.');
    }
  }

  void _finish(_AccessStatus status, String? message) {
    if (!mounted) return;
    setState(() {
      _isAuthenticating = false;
      _status = status;
      _message = message;
    });
  }

  String _authErrorMessage(PlatformException error) {
    switch (error.code) {
      case 'NotAvailable':
        return 'المصادقة غير متاحة على هذا الجهاز.';
      case 'NotEnrolled':
        return 'لم يتم إعداد بصمة أو قفل شاشة على هذا الجهاز.';
      case 'PasscodeNotSet':
        return 'لم يتم تعيين رمز قفل للجهاز.';
      case 'LockedOut':
        return 'تم إيقاف المصادقة مؤقتاً بعد محاولات فاشلة. حاول لاحقاً.';
      case 'PermanentlyLockedOut':
        return 'تم إيقاف المصادقة نهائياً. أعد تفعيلها من إعدادات الجهاز.';
      case 'auth_in_progress':
        return 'هناك عملية مصادقة قيد التنفيذ.';
      case 'no_activity':
      case 'no_fragment_activity':
        return 'تعذر عرض نافذة المصادقة. أعد فتح التطبيق وحاول مرة أخرى.';
      default:
        return 'تعذر إكمال المصادقة. حاول مرة أخرى.';
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
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    switch (_status) {
      case _AccessStatus.checking:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );
      case _AccessStatus.authenticated:
        return const SettingsScreen();
      case _AccessStatus.lockedOut:
      case _AccessStatus.noDeviceLock:
        return _buildAccessGate(
          showContinue: _status == _AccessStatus.noDeviceLock,
        );
    }
  }

  Widget _buildAccessGate({required bool showContinue}) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.lock_outline, size: 56),
              const SizedBox(height: 16),
              const Text(
                'المصادقة مطلوبة لحماية مستمسكاتك',
                style: TextStyle(fontSize: 18),
                textAlign: TextAlign.center,
              ),
              if (_message != null) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _message!,
                  style: const TextStyle(color: Colors.orangeAccent),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _isAuthenticating ? null : _authenticate,
                icon: const Icon(Icons.fingerprint),
                label: const Text('إعادة المحاولة'),
              ),
              if (showContinue) ...<Widget>[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _isAuthenticating
                      ? null
                      : () => setState(
                          () => _status = _AccessStatus.authenticated,
                        ),
                  child: const Text('المتابعة بدون قفل الجهاز'),
                ),
                const SizedBox(height: 8),
                const Text(
                  'لا يوجد قفل على هذا الجهاز، لذا يمكن لأي شخص يفتح التطبيق '
                  'أن يرى مستمسكاتك.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
