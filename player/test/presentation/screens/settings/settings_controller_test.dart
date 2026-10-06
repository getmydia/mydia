import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/user_settings.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';

import '../../../core/sources/mydia/bound_mydia_harness.dart';

void main() {
  Future<UserSettings> load(Map<String, MydiaCredentials> accounts) async {
    final h = await boundMydiaHarness(accounts);
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
