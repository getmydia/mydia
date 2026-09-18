import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_service.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  test('the stats panel is off until the viewer turns it on', () async {
    final service = SettingsService(storage: MockAuthStorage());

    expect(await service.getStatsOverlayEnabled(), isFalse);
  });

  test('the choice round-trips through storage', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);

    await service.setStatsOverlayEnabled(true);
    expect(await service.getStatsOverlayEnabled(), isTrue);
    expect(storage.contents, {'stats_overlay_enabled': 'true'});

    await service.setStatsOverlayEnabled(false);
    expect(await service.getStatsOverlayEnabled(), isFalse);
  });

  // A device-level choice, like crash reporting: signing out of one server
  // must not silently put the panel back on screen, or take it away.
  test('clearSettings leaves the stats choice alone', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);

    await service.setStatsOverlayEnabled(true);
    await service.setAutoSkipSegments(true);
    await service.clearSettings();

    expect(storage.contents, {'stats_overlay_enabled': 'true'});
  });
}
