import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/user_settings.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';

import '../../../core/sources/mydia/mydia_account_harness.dart';
import '../../../test_utils/mock_auth_storage.dart';

void main() {
  Future<UserSettings> load(Map<String, MydiaCredentials> accounts) async {
    // In-memory settings: the real service reads flutter_secure_storage, and
    // an earlier file in a shared isolate can leave a never-completing read of
    // the same key in NativeAuthStorage's static in-flight map.
    final h = await mydiaAccountHarness(accounts, overrides: [
      coreSettingsServiceProvider
          .overrideWithValue(SettingsService(storage: MockAuthStorage())),
    ]);
    addTearDown(h.container.dispose);
    await h.container.read(sourceRecordsProvider.future);
    return h.container.read(settingsControllerProvider.future);
  }

  test('identity comes from the active server credentials', () async {
    final settings = await load({
      'a': const MydiaCredentials(
        instanceId: 'a',
        accessToken: 't',
        serverUrl: 'https://media.example.test',
        username: 'ada',
      ),
    });
    expect(settings.serverUrl, 'https://media.example.test');
    expect(settings.username, 'ada');
  });

  test('a p2p account with no URL shows its display name', () async {
    final settings = await load({
      'a': const MydiaCredentials(
        instanceId: 'a',
        accessToken: 't',
        nodeAddr: '{"id":"node1"}',
      ),
    });
    expect(settings.serverUrl, 'Server a');
    expect(settings.username, '');
  });

  test('no server reads as blank', () async {
    final settings = await load({});
    expect(settings.serverUrl, '');
    expect(settings.username, '');
  });
}
