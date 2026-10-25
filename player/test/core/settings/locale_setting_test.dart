import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/locale_setting.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';

import '../../test_utils/mock_auth_storage.dart';

/// Holds the first write until released, so a second write started meanwhile
/// would land first if the notifier did not queue them.
class _SlowFirstWriteStorage extends MockAuthStorage {
  final Completer<void> _gate = Completer<void>();
  bool _firstSeen = false;

  void releaseFirstWrite() => _gate.complete();

  @override
  Future<void> write(String key, String value) async {
    if (!_firstSeen) {
      _firstSeen = true;
      await _gate.future;
    }
    return super.write(key, value);
  }
}

void main() {
  ProviderContainer containerWith(MockAuthStorage storage) {
    final c = ProviderContainer(overrides: [
      coreSettingsServiceProvider
          .overrideWithValue(SettingsService(storage: storage)),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('follows the device before storage answers', () {
    final c = containerWith(MockAuthStorage());
    expect(c.read(localeSettingProvider), isNull);
  });

  test('loads a stored supported language', () async {
    final storage = MockAuthStorage();
    await storage.write('interface_locale', 'es');
    final c = containerWith(storage);
    c.read(localeSettingProvider);
    await settle();
    expect(c.read(localeSettingProvider), const Locale('es'));
  });

  test('ignores a stored language the app no longer ships', () async {
    final storage = MockAuthStorage();
    await storage.write('interface_locale', 'xx');
    final c = containerWith(storage);
    c.read(localeSettingProvider);
    await settle();
    expect(c.read(localeSettingProvider), isNull);
  });

  test('set publishes at once and persists; null clears', () async {
    final storage = MockAuthStorage();
    final c = containerWith(storage);
    await c.read(localeSettingProvider.notifier).set(const Locale('es'));
    expect(c.read(localeSettingProvider), const Locale('es'));
    expect(storage.contents['interface_locale'], 'es');
    await c.read(localeSettingProvider.notifier).set(null);
    expect(c.read(localeSettingProvider), isNull);
    expect(storage.contents.containsKey('interface_locale'), isFalse);
  });

  test('a choice made before the stored read lands is kept', () async {
    final storage = MockAuthStorage();
    await storage.write('interface_locale', 'es');
    final c = containerWith(storage);
    c.read(localeSettingProvider);
    unawaited(c.read(localeSettingProvider.notifier).set(const Locale('en')));
    await settle();
    expect(c.read(localeSettingProvider), const Locale('en'));
  });

  test('overlapping sets reach storage in call order', () async {
    final storage = _SlowFirstWriteStorage();
    final c = containerWith(storage);
    final notifier = c.read(localeSettingProvider.notifier);
    final first = notifier.set(const Locale('es'));
    final second = notifier.set(null);
    storage.releaseFirstWrite();
    await Future.wait([first, second]);
    expect(c.read(localeSettingProvider), isNull);
    expect(storage.contents.containsKey('interface_locale'), isFalse);
  });

  group('served by a Mydia instance', () {
    ProviderContainer hostedWith(MockAuthStorage storage, String? hostCode) {
      final c = ProviderContainer(overrides: [
        coreSettingsServiceProvider
            .overrideWithValue(SettingsService(storage: storage)),
        hostLocaleProvider
            .overrideWithValue(LocaleSetting.fromHostCode(hostCode)),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    test("the launching user's language beats this browser's stored one",
        () async {
      final storage = MockAuthStorage();
      await storage.write('interface_locale', 'en');
      final c = hostedWith(storage, 'es');
      expect(c.read(localeSettingProvider), const Locale('es'));
      await settle();
      expect(c.read(localeSettingProvider), const Locale('es'));
    });

    test('a choice in the player still applies for the session', () async {
      final c = hostedWith(MockAuthStorage(), 'es');
      c.read(localeSettingProvider);
      await c.read(localeSettingProvider.notifier).set(const Locale('en'));
      expect(c.read(localeSettingProvider), const Locale('en'));
    });

    test('no language sent falls back to the stored choice', () async {
      final storage = MockAuthStorage();
      await storage.write('interface_locale', 'es');
      final c = hostedWith(storage, null);
      c.read(localeSettingProvider);
      await settle();
      expect(c.read(localeSettingProvider), const Locale('es'));
    });
  });

  group('fromHostCode', () {
    test('maps a shipped language', () {
      expect(LocaleSetting.fromHostCode('es'), const Locale('es'));
    });

    test('drops a region the player does not ship', () {
      expect(LocaleSetting.fromHostCode('es_MX'), const Locale('es'));
    });

    test('an untranslated language shows English, like the web UI', () {
      expect(LocaleSetting.fromHostCode('pt_BR'), const Locale('en'));
    });

    test('no code is no preference', () {
      expect(LocaleSetting.fromHostCode(null), isNull);
      expect(LocaleSetting.fromHostCode(''), isNull);
    });
  });

  test('a failed write keeps the choice', () async {
    final storage = MockAuthStorage()..failAllWrites = true;
    final c = containerWith(storage);
    await c.read(localeSettingProvider.notifier).set(const Locale('es'));
    expect(c.read(localeSettingProvider), const Locale('es'));
    expect(storage.contents.containsKey('interface_locale'), isFalse);
  });
}
