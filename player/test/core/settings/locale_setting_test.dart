import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/locale_setting.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';

import '../../test_utils/mock_auth_storage.dart';

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

  test('a failed write keeps the choice', () async {
    final storage = MockAuthStorage()..failAllWrites = true;
    final c = containerWith(storage);
    await c.read(localeSettingProvider.notifier).set(const Locale('es'));
    expect(c.read(localeSettingProvider), const Locale('es'));
    expect(storage.contents.containsKey('interface_locale'), isFalse);
  });
}
