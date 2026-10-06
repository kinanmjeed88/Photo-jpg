import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists the user's scanning preferences between launches.
///
/// Before this existed, every choice on the settings screen (document types,
/// display method, file name, frame and smart-recognition switches) was lost as
/// soon as the process ended, even though `shared_preferences` was already a
/// declared dependency.
///
/// The store is intentionally small and defensive: it owns exactly one JSON
/// document, writes are debounced, and a missing platform implementation (unit
/// tests, unsupported platform) or a corrupt payload can never break the UI.
///
/// It deals in plain JSON maps rather than in the state class itself, which
/// keeps the dependency direction one-way (`app_state` -> store) and makes the
/// store reusable for any future preference document.
class AppSettingsStore {
  AppSettingsStore({SharedPreferences? preferences})
    : _preferences = preferences;

  static const String storageKey = 'photo_jpg.app_state.v1';
  static const Duration writeDebounce = Duration(milliseconds: 400);

  SharedPreferences? _preferences;
  Timer? _pendingWrite;
  Map<String, Object?> _pendingPayload = const <String, Object?>{};
  bool _hasPendingWrite = false;
  bool _persistenceEnabled = false;
  bool _disposed = false;

  /// Reads the stored payload and enables persistence.
  ///
  /// Returns `null` when nothing valid was ever written, or when the platform
  /// implementation is unavailable. A payload recorded by [save] *before* the
  /// load finished is never lost: the store keeps accepting writes while
  /// disabled and flushes them once persistence is enabled, so a change made in
  /// the first few frames cannot be dropped or overwritten by stale data.
  Future<Map<String, Object?>?> loadPayload() async {
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      final raw = preferences.getString(storageKey);
      final stored = _decode(raw);
      _persistenceEnabled = true;
      if (_hasPendingWrite) {
        // A newer value already exists in memory (the user interacted while the
        // preferences were loading); it wins over what was on disk.
        unawaited(_write(_pendingPayload));
      }
      return stored;
    } catch (error) {
      // Reading preferences is best effort: fall back to the documented
      // defaults instead of surfacing a startup failure.
      debugPrint('تعذر تحميل الإعدادات المحفوظة: $error');
      return null;
    }
  }

  Map<String, Object?>? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return decoded.map<String, Object?>(
        (key, value) => MapEntry(key.toString(), value),
      );
    } on FormatException catch (error) {
      debugPrint('الإعدادات المحفوظة غير صالحة وتم تجاهلها: $error');
      return null;
    }
  }

  /// Records [payload] and schedules a debounced write.
  ///
  /// Dragging a document emits a layout update on every frame, so an immediate
  /// write per change would hammer the platform channel.
  ///
  /// Writes are accepted before the first load finishes (so an early change is
  /// never dropped) but never after [dispose], which must leave no timer
  /// behind.
  void save(Map<String, Object?> payload) {
    if (_disposed) return;
    _pendingPayload = payload;
    _hasPendingWrite = true;
    _pendingWrite?.cancel();
    _pendingWrite = Timer(writeDebounce, () => unawaited(flush()));
  }

  /// Writes any pending change immediately (used when the app is paused).
  ///
  /// Safe to call before persistence is enabled: the payload stays pending and
  /// is written as soon as [loadPayload] succeeds.
  Future<void> flush() async {
    _pendingWrite?.cancel();
    _pendingWrite = null;
    if (!_hasPendingWrite) return;
    await _write(_pendingPayload);
  }

  Future<void> _write(Map<String, Object?> payload) async {
    if (!_persistenceEnabled) return;
    try {
      final preferences = _preferences ??=
          await SharedPreferences.getInstance();
      await preferences.setString(storageKey, jsonEncode(payload));
      _hasPendingWrite = false;
    } catch (error) {
      // Keep the value pending so the next flush (app pause) can retry.
      debugPrint('تعذر حفظ الإعدادات: $error');
    }
  }

  /// Cancels scheduling and releases the store.
  ///
  /// A payload that is still pending is written once more, because disposal can
  /// happen without another life-cycle callback (for example when the provider
  /// container is torn down by a test or a hot restart).
  void dispose() {
    _pendingWrite?.cancel();
    _pendingWrite = null;
    if (_hasPendingWrite && _persistenceEnabled) {
      unawaited(_write(_pendingPayload));
    }
    _persistenceEnabled = false;
    _disposed = true;
  }
}
