import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/theme/theme_preset.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  test('round-trips the preset name under theme_preset', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);
    expect(await service.getThemePreset(), isNull);
    await service.setThemePreset(ThemePreset.oledBlack);
    expect(storage.contents['theme_preset'], 'oledBlack');
    expect(await service.getThemePreset(), 'oledBlack');
  });

  test('clearSettings keeps the device-level preset', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);
    await service.setThemePreset(ThemePreset.slate);
    await service.clearSettings();
    expect(await service.getThemePreset(), 'slate');
  });
}
