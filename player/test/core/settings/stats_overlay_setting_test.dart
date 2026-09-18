import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/settings/stats_overlay_setting.dart';

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
    await SettingsService(storage: storage).setStatsOverlayEnabled(true);
    final container = containerWith(storage);

    expect(
      await container.read(statsOverlayEnabledProvider.future),
      isTrue,
    );
  });

  test('resolves false when nothing is stored', () async {
    final container = containerWith(MockAuthStorage());

    expect(
      await container.read(statsOverlayEnabledProvider.future),
      isFalse,
    );
  });

  // The switch and the panel are on screen together on desktop, so the
  // flag has to read back before the write completes.
  test('set publishes before the write lands', () async {
    final storage = MockAuthStorage();
    final container = containerWith(storage);
    await container.read(statsOverlayEnabledProvider.future);

    final pending =
        container.read(statsOverlayEnabledProvider.notifier).set(true);

    expect(container.read(statsOverlayEnabledProvider).value, isTrue);
    await pending;
    expect(storage.contents['stats_overlay_enabled'], 'true');
  });

  // A throwing write must not escape `set` as an unhandled asynchronous
  // error: both call sites (the quality sheet and the settings row) discard
  // the returned future. The optimistic state is not rolled back either --
  // that is the documented behaviour this test is not reopening.
  test('a throwing write does not escape set, and the state stays flipped',
      () async {
    final storage = MockAuthStorage()..failAllWrites = true;
    final container = containerWith(storage);
    await container.read(statsOverlayEnabledProvider.future);

    await container.read(statsOverlayEnabledProvider.notifier).set(true);

    expect(container.read(statsOverlayEnabledProvider).value, isTrue);
    expect(storage.contents.containsKey('stats_overlay_enabled'), isFalse);
  });
}
