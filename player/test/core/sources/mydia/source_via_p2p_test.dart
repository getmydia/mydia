import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/device_profile.dart';
import 'package:player/core/player/device_profile_provider.dart';
import 'package:player/core/router/legacy_routes.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/source_link.dart';
import 'package:player/core/sources/sources_providers.dart';

import 'mydia_account_harness.dart';

void main() {
  group('source link', () {
    const urlAccount = MydiaCredentials(
        instanceId: 'a',
        accessToken: 'tok-a',
        serverUrl: 'https://a.example.test');
    const p2pAccount = MydiaCredentials(
        instanceId: 'b', accessToken: 'tok-b', nodeAddr: '{"id":"node-b"}');

    Future<ProviderContainer> containerWith(
      Map<String, MydiaCredentials> accounts,
    ) async {
      final h = await mydiaAccountHarness(accounts, overrides: [
        deviceProfileHolderProvider.overrideWithValue(DeviceProfileHolder()),
      ]);
      addTearDown(h.container.dispose);
      await h.container.read(sourceRecordsProvider.future);
      return h.container;
    }

    test('a URL account is not via p2p', () async {
      final container = await containerWith({'a': urlAccount});
      final id = container.read(mydiaSourceIdsProvider).single;
      expect(await container.read(sourceViaP2pProvider(id).future), isFalse);
    });

    test('a p2p account is via p2p', () async {
      final container = await containerWith({'b': p2pAccount});
      final id = container.read(mydiaSourceIdsProvider).single;
      expect(await container.read(sourceViaP2pProvider(id).future), isTrue);
    });
  });
}
