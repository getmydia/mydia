import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/subtitle_size.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/settings/subtitle_size_setting.dart';

import '../../test_utils/mock_auth_storage.dart';

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

  test('clearSettings leaves the stored size alone', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);
    await service.setSubtitleSize(SubtitleSize.large);

    await service.clearSettings();

    expect(await service.getSubtitleSize(), SubtitleSize.large);
  });
}
