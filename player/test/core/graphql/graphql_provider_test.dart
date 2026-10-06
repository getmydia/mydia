import 'dart:io';
import 'package:hive_ce/hive.dart' show Hive;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart'
    show GraphQLClient, HiveStore;
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/core/sources/mydia/bound_mydia.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/player/device_profile.dart';

import '../sources/mydia/bound_mydia_harness.dart';

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

  group('derived from the bound Mydia instance', () {
    const urlAccount = MydiaCredentials(
        instanceId: 'a',
        accessToken: 'tok-a',
        serverUrl: 'https://a.example.test');
    const p2pAccount = MydiaCredentials(
        instanceId: 'b', accessToken: 'tok-b', nodeAddr: '{"id":"node-b"}');

    late Directory hiveDir;

    setUpAll(() async {
      hiveDir = Directory.systemTemp.createTempSync('graphql_provider_test');
      Hive.init(hiveDir.path);
      await HiveStore.open();
    });

    tearDownAll(() async {
      await Hive.close();
      hiveDir.deleteSync(recursive: true);
    });

    Future<ProviderContainer> containerWith(
      Map<String, MydiaCredentials> accounts, {
      void Function()? onReset,
    }) async {
      final h = await boundMydiaHarness(accounts, overrides: [
        deviceProfileHolderProvider.overrideWithValue(DeviceProfileHolder()),
        if (onReset != null)
          graphqlCacheResetProvider.overrideWithValue(onReset),
      ]);
      addTearDown(h.container.dispose);
      await h.container.read(sourceRecordsProvider.future);
      await h.container.read(legacyInstanceIdProvider.future);
      return h.container;
    }

    test('graphqlClientProvider is null with no Mydia account', () async {
      final container = await containerWith({});
      expect(container.read(graphqlClientProvider), isNull);
    });

    test('graphqlClientProvider is a client once an account exists', () async {
      final container = await containerWith({'a': urlAccount});
      expect(container.read(graphqlClientProvider), isA<GraphQLClient>());
      expect(await container.read(asyncGraphqlClientProvider.future),
          isA<GraphQLClient>());
    });

    test('removing the bound instance rebuilds the client and resets the cache',
        () async {
      var resets = 0;
      final container = await containerWith({'a': urlAccount, 'b': p2pAccount},
          onReset: () => resets++);
      container.listen(graphqlClientProvider, (_, __) {});
      final before = container.read(graphqlClientProvider);
      expect(before, isNotNull);

      await container.read(sourceRecordsProvider.notifier).removeAccount('ma');

      final after = container.read(graphqlClientProvider);
      expect(after, isNotNull);
      expect(after, isNot(same(before)));
      expect(resets, 1);
    });

    test('serverUrlProvider and authTokenProvider read the bound credentials',
        () async {
      final container = await containerWith({'a': urlAccount});
      expect(await container.read(serverUrlProvider.future),
          'https://a.example.test');
      expect(await container.read(authTokenProvider.future), 'tok-a');
    });

    test('connectionProvider is direct for a URL account', () async {
      final container = await containerWith({'a': urlAccount});
      container.listen(connectionProvider, (_, __) {});
      await container.read(boundMydiaCredentialsProvider.future);
      expect(container.read(connectionProvider).isP2PMode, isFalse);
    });

    test('connectionProvider is p2p with the node address for a p2p account',
        () async {
      final container = await containerWith({'b': p2pAccount});
      container.listen(connectionProvider, (_, __) {});
      await container.read(boundMydiaCredentialsProvider.future);
      final state = container.read(connectionProvider);
      expect(state.isP2PMode, isTrue);
      expect(state.serverNodeAddr, '{"id":"node-b"}');
    });
  });
}
