import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_service.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  test('commercials are skipped until the viewer turns it off', () async {
    final service = SettingsService(storage: MockAuthStorage());

    expect(await service.getAutoSkipCommercials(), isTrue);
  });

  test('the choice round-trips through storage', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);

    await service.setAutoSkipCommercials(false);
    expect(await service.getAutoSkipCommercials(), isFalse);
    expect(storage.contents, {'auto_skip_commercials': 'false'});

    await service.setAutoSkipCommercials(true);
    expect(await service.getAutoSkipCommercials(), isTrue);
  });

  test('clearSettings removes the choice', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);

    await service.setAutoSkipCommercials(false);
    await service.clearSettings();

    expect(storage.contents, isEmpty);
    expect(await service.getAutoSkipCommercials(), isTrue);
  });
}
