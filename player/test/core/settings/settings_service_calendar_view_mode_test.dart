import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_service.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  test('an unset calendar view mode reads back as null', () async {
    final service = SettingsService(storage: MockAuthStorage());

    expect(await service.getCalendarViewMode(), isNull);
  });

  test('a stored calendar view mode round-trips', () async {
    final service = SettingsService(storage: MockAuthStorage());

    await service.setCalendarViewMode('agenda');

    expect(await service.getCalendarViewMode(), 'agenda');
  });
}
