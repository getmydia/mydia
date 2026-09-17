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
}
