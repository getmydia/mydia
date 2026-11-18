import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/legacy_mac_video_output_setting.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';

import '../../test_utils/mock_auth_storage.dart';

/// A settings service whose read of the legacy setting waits for the test.
class _HeldRead extends SettingsService {
  _HeldRead() : super(storage: MockAuthStorage());

  final read = Completer<bool>();
  final writes = <bool>[];

  @override
  Future<bool> getLegacyMacVideoOutput() => read.future;

  @override
  Future<void> setLegacyMacVideoOutput(bool enabled) async {
    writes.add(enabled);
  }
}

void main() {
  test('a choice made before the first read lands is kept', () async {
    final settings = _HeldRead();
    final container = ProviderContainer(overrides: [
      coreSettingsServiceProvider.overrideWithValue(settings),
    ]);
    addTearDown(container.dispose);
    final sub =
        container.listen(legacyMacVideoOutputProvider, (previous, next) {});
    addTearDown(sub.close);

    await container.read(legacyMacVideoOutputProvider.notifier).set(true);
    // The read started before the write, so it answers the old value.
    settings.read.complete(false);
    await container.read(legacyMacVideoOutputProvider.future);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(legacyMacVideoOutputProvider).value, isTrue);
    expect(settings.writes, [true]);
  });

  test('resolves to the stored value without a choice', () async {
    final settings = _HeldRead();
    final container = ProviderContainer(overrides: [
      coreSettingsServiceProvider.overrideWithValue(settings),
    ]);
    addTearDown(container.dispose);
    final sub =
        container.listen(legacyMacVideoOutputProvider, (previous, next) {});
    addTearDown(sub.close);

    settings.read.complete(true);
    expect(await container.read(legacyMacVideoOutputProvider.future), isTrue);
  });
}
