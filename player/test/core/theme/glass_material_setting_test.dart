import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/theme/glass_material.dart';
import 'package:player/core/theme/theme_providers.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  ProviderContainer containerWith(MockAuthStorage storage) {
    final c = ProviderContainer(overrides: [
      coreSettingsServiceProvider
          .overrideWithValue(SettingsService(storage: storage)),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('starts on Liquid Glass on iOS before storage answers', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final c = containerWith(MockAuthStorage());
    expect(c.read(glassMaterialSettingProvider), GlassMaterial.liquid);
  });

  test('starts on Frosted on Android', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final c = containerWith(MockAuthStorage());
    expect(c.read(glassMaterialSettingProvider), GlassMaterial.frosted);
  });

  test('loads the stored material', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final storage = MockAuthStorage();
    await storage.write('glass_material', 'liquid');
    final c = containerWith(storage);
    c.read(glassMaterialSettingProvider);
    await settle();
    expect(c.read(glassMaterialSettingProvider), GlassMaterial.liquid);
  });

  test('set publishes at once and persists', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final storage = MockAuthStorage();
    final c = containerWith(storage);
    await c
        .read(glassMaterialSettingProvider.notifier)
        .set(GlassMaterial.frosted);
    expect(c.read(glassMaterialSettingProvider), GlassMaterial.frosted);
    expect(storage.contents['glass_material'], 'frosted');
  });

  test('a choice made before the stored read lands is kept', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final storage = MockAuthStorage();
    await storage.write('glass_material', 'frosted');
    final c = containerWith(storage);
    c.read(glassMaterialSettingProvider);
    unawaited(c
        .read(glassMaterialSettingProvider.notifier)
        .set(GlassMaterial.liquid));
    await settle();
    expect(c.read(glassMaterialSettingProvider), GlassMaterial.liquid);
  });

  test('a failed write keeps the choice for the session', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final storage = MockAuthStorage()..failAllWrites = true;
    final c = containerWith(storage);
    await c
        .read(glassMaterialSettingProvider.notifier)
        .set(GlassMaterial.liquid);
    expect(c.read(glassMaterialSettingProvider), GlassMaterial.liquid);
    expect(storage.contents.containsKey('glass_material'), isFalse);
  });
}
