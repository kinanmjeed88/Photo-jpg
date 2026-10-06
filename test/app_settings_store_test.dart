import 'package:doc_scanner_app/services/app_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persistence is exercised against the in-memory store that
/// `shared_preferences` provides for tests, which is the same code path the
/// plugin uses on a device minus the platform channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('a fresh installation has no payload', () async {
    final store = AppSettingsStore();
    addTearDown(store.dispose);

    expect(await store.loadPayload(), isNull);
  });

  test('saved preferences survive a round trip', () async {
    final first = AppSettingsStore();
    addTearDown(first.dispose);
    await first.loadPayload();
    first.save(<String, Object?>{
      'hasNationalId': true,
      'fileName': 'مستمسكاتي 2026',
      'displayMethod': 'twoPages',
    });
    await first.flush();

    final second = AppSettingsStore();
    addTearDown(second.dispose);
    final payload = await second.loadPayload();

    expect(payload, isNotNull);
    expect(payload!['hasNationalId'], isTrue);
    expect(payload['fileName'], 'مستمسكاتي 2026');
    expect(payload['displayMethod'], 'twoPages');
  });

  test('a change made before the load finishes is never lost', () async {
    final store = AppSettingsStore();
    addTearDown(store.dispose);

    // The user can toggle a switch while the preferences are still loading.
    store.save(<String, Object?>{'smartRecognition': true});
    await store.loadPayload();
    await store.flush();

    final reloaded = AppSettingsStore();
    addTearDown(reloaded.dispose);
    final payload = await reloaded.loadPayload();

    expect(payload!['smartRecognition'], isTrue);
  });

  test('the debounce timer writes without an explicit flush', () async {
    final store = AppSettingsStore();
    addTearDown(store.dispose);
    await store.loadPayload();
    store.save(<String, Object?>{'addFrame': true});

    // Longer than AppSettingsStore.writeDebounce.
    await Future<void>.delayed(
      AppSettingsStore.writeDebounce + const Duration(milliseconds: 150),
    );

    final reloaded = AppSettingsStore();
    addTearDown(reloaded.dispose);
    final payload = await reloaded.loadPayload();

    expect(payload!['addFrame'], isTrue);
  });

  test('flushing without a pending change is a no-op', () async {
    final store = AppSettingsStore();
    addTearDown(store.dispose);
    await store.loadPayload();

    await store.flush();

    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(AppSettingsStore.storageKey), isNull);
  });

  test('a corrupt stored payload falls back to the defaults', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppSettingsStore.storageKey: 'this is not json',
    });

    final store = AppSettingsStore();
    addTearDown(store.dispose);

    expect(await store.loadPayload(), isNull);
  });

  test('a payload of the wrong shape is ignored', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      AppSettingsStore.storageKey: '[1, 2, 3]',
    });

    final store = AppSettingsStore();
    addTearDown(store.dispose);

    expect(await store.loadPayload(), isNull);
  });

  test('a disposed store stops accepting writes', () async {
    final store = AppSettingsStore();
    await store.loadPayload();
    store.dispose();

    store.save(<String, Object?>{'smartRecognition': true});
    await store.flush();

    final reloaded = AppSettingsStore();
    addTearDown(reloaded.dispose);
    expect(await reloaded.loadPayload(), isNull);
  });
}
