import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/core/router/legacy_routes.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/source_link.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/cache/fetch_log.dart';
import '../../test_utils/query_keys.dart';
import 'package:player/core/player/device_profile.dart';

import '../sources/mydia/mydia_account_harness.dart';

/// Always fails [clearAll], to prove a storage error cannot escape
/// [applyDetectedProfile] and break the "detectDeviceProfile never throws"
/// contract it feeds into.
class _ThrowingClearFetchLog extends InMemoryFetchLog {
  @override
  Future<void> clearAll() => throw StateError('boom');
}

void main() {
  group('applyDetectedProfile', () {
    const profile = DeviceProfile.webDefault();
    const otherProfile = DeviceProfile(
      containers: ['mp4'],
      videoCodecs: ['h264'],
      audioCodecs: ['aac'],
      hdrFormats: [],
    );

    test('writes the profile onto the holder', () async {
      final holder = DeviceProfileHolder();
      final fetchLog = InMemoryFetchLog();

      await applyDetectedProfile(holder, profile, fetchLog);

      expect(holder.profile, profile);
    });

    test('clears the fetch log on the null-to-non-null transition', () async {
      final holder = DeviceProfileHolder();
      final fetchLog = InMemoryFetchLog({
        QueryKeys.home: DateTime(2026, 8, 22),
        QueryKeys.favorites: DateTime(2026, 8, 22),
      });

      await applyDetectedProfile(holder, profile, fetchLog);

      expect(fetchLog.lastFetchedAt(QueryKeys.home), isNull);
      expect(fetchLog.lastFetchedAt(QueryKeys.favorites), isNull);
    });

    test('does not clear the fetch log again on a subsequent write', () async {
      final holder = DeviceProfileHolder();
      final fetchLog = InMemoryFetchLog();

      // First write: null -> non-null, clears (nothing to observe yet, the
      // log starts empty).
      await applyDetectedProfile(holder, profile, fetchLog);

      // Simulate a later write landing on an already-resolved holder, and
      // seed an entry that a second clear would wipe.
      await fetchLog.record(QueryKeys.home, DateTime(2026, 8, 22));
      await applyDetectedProfile(holder, otherProfile, fetchLog);

      expect(fetchLog.lastFetchedAt(QueryKeys.home), isNotNull,
          reason: 'a write onto an already-set holder must not clear again');
      // The second write still lands, even though it did not trigger a clear.
      expect(holder.profile, otherProfile);
    });

    test('a failing clearAll does not propagate or block the write', () async {
      final holder = DeviceProfileHolder();
      final fetchLog = _ThrowingClearFetchLog();

      await expectLater(
        applyDetectedProfile(holder, profile, fetchLog),
        completes,
      );
      expect(holder.profile, profile);
    });
  });

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
