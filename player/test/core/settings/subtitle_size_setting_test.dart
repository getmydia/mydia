import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/subtitle_size.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/settings/subtitle_size_setting.dart';

import '../../test_utils/mock_auth_storage.dart';

/// Storage whose reads and writes complete only when the test says so.
class _GatedStorage extends MockAuthStorage {
  final List<Completer<void>> writeGates = [];
  final List<String> startedWrites = [];
  Completer<void>? readGate;

  @override
  Future<String?> read(String key) async {
    await readGate?.future;
    return super.read(key);
  }

  @override
  Future<void> write(String key, String value) async {
    startedWrites.add(value);
    final gate = Completer<void>();
    writeGates.add(gate);
    await gate.future;
    await super.write(key, value);
  }
}

void main() {
  ProviderContainer containerWith(MockAuthStorage storage) {
    final container = ProviderContainer(
      overrides: [
        coreSettingsServiceProvider
            .overrideWithValue(SettingsService(storage: storage)),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('resolves to the stored value', () async {
    final storage = MockAuthStorage();
    await SettingsService(storage: storage).setSubtitleSize(SubtitleSize.large);

    expect(
      await containerWith(storage).read(subtitleSizeSettingProvider.future),
      SubtitleSize.large,
    );
  });

  test('resolves medium when nothing is stored', () async {
    expect(
      await containerWith(MockAuthStorage())
          .read(subtitleSizeSettingProvider.future),
      SubtitleSize.medium,
    );
  });

  test('resolves medium for an unrecognised stored value', () async {
    final storage = MockAuthStorage();
    await storage.write('subtitle_size', 'gigantic');

    expect(
      await containerWith(storage).read(subtitleSizeSettingProvider.future),
      SubtitleSize.medium,
    );
  });

  // The sheet resizes the text behind it as the viewer steps, so the value
  // has to read back before the write completes.
  test('set publishes before the write lands', () async {
    final storage = MockAuthStorage();
    final container = containerWith(storage);
    await container.read(subtitleSizeSettingProvider.future);

    final pending = container
        .read(subtitleSizeSettingProvider.notifier)
        .set(SubtitleSize.extraLarge);

    expect(container.read(subtitleSizeSettingProvider).value,
        SubtitleSize.extraLarge);
    await pending;
    expect(storage.contents['subtitle_size'], 'extraLarge');
  });

  test('a throwing write does not escape set, and the state stays changed',
      () async {
    final storage = MockAuthStorage()..failAllWrites = true;
    final container = containerWith(storage);
    await container.read(subtitleSizeSettingProvider.future);

    await container
        .read(subtitleSizeSettingProvider.notifier)
        .set(SubtitleSize.small);

    expect(
        container.read(subtitleSizeSettingProvider).value, SubtitleSize.small);
    expect(storage.contents.containsKey('subtitle_size'), isFalse);
  });

  test('a selection made during the first read survives that read', () async {
    final storage = _GatedStorage()..readGate = Completer<void>();
    storage.seedData({'subtitle_size': 'small'});
    final container = containerWith(storage);
    // Auto-dispose would drop the notifier between the awaits below.
    container.listen(subtitleSizeSettingProvider, (_, __) {});
    final initial = container.read(subtitleSizeSettingProvider.future);

    final pending = container
        .read(subtitleSizeSettingProvider.notifier)
        .set(SubtitleSize.large);
    storage.readGate!.complete();
    await initial;
    await Future<void>.delayed(Duration.zero);
    storage.writeGates.single.complete();
    await pending;

    expect(
        container.read(subtitleSizeSettingProvider).value, SubtitleSize.large);
  });

  test('writes run in call order, so the last selection is persisted last',
      () async {
    final storage = _GatedStorage();
    final container = containerWith(storage);
    container.listen(subtitleSizeSettingProvider, (_, __) {});
    await container.read(subtitleSizeSettingProvider.future);
    final notifier = container.read(subtitleSizeSettingProvider.notifier);

    final first = notifier.set(SubtitleSize.large);
    final second = notifier.set(SubtitleSize.extraLarge);
    await Future<void>.delayed(Duration.zero);

    expect(storage.startedWrites, ['large']);
    expect(container.read(subtitleSizeSettingProvider).value,
        SubtitleSize.extraLarge);

    storage.writeGates[0].complete();
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(storage.startedWrites, ['large', 'extraLarge']);

    storage.writeGates[1].complete();
    await second;
    expect(storage.contents['subtitle_size'], 'extraLarge');
  });

  test('a failed write does not break the chain', () async {
    final storage = MockAuthStorage()..failAllWrites = true;
    final container = containerWith(storage);
    await container.read(subtitleSizeSettingProvider.future);
    final notifier = container.read(subtitleSizeSettingProvider.notifier);

    await notifier.set(SubtitleSize.small);
    storage.failAllWrites = false;
    await notifier.set(SubtitleSize.large);

    expect(storage.contents['subtitle_size'], 'large');
  });

  test('clearSettings leaves the stored size alone', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);
    await service.setSubtitleSize(SubtitleSize.large);

    await service.clearSettings();

    expect(await service.getSubtitleSize(), SubtitleSize.large);
  });
}
