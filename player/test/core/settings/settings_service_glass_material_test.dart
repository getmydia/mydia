import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/theme/glass_material.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  test('round-trips the material name under glass_material', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);
    expect(await service.getGlassMaterial(), isNull);
    await service.setGlassMaterial(GlassMaterial.liquid);
    expect(storage.contents['glass_material'], 'liquid');
    expect(await service.getGlassMaterial(), 'liquid');
  });

  test('clearSettings keeps the device-level material', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);
    await service.setGlassMaterial(GlassMaterial.frosted);
    await service.clearSettings();
    expect(await service.getGlassMaterial(), 'frosted');
  });
}
