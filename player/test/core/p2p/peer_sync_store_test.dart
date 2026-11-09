import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show PlatformInt64Util;
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/p2p/peer_sync_records.dart';
import 'package:player/core/p2p/peer_sync_store.dart';

void main() {
  group('Canonical sync keys', () {
    test('derives tmdb and unmatched file keys', () {
      expect(tmdbMovieSyncKey(42), 'tmdb:movie:42');
      expect(tmdbEpisodeSyncKey(42, 2, 5), 'tmdb:ep:42:2:5');
      expect(unmatchedFileSyncKey('acc1', 'file99'), 'file:acc1:file99');
      expect(
        pinSyncKey(isShow: true, groupKey: 'harbor-of-echoes'),
        'pin:s:harbor-of-echoes',
      );
      expect(
        pinSyncKey(isShow: false, groupKey: 'fable-of-glass'),
        'pin:m:fable-of-glass',
      );
    });

    test('syncKeyForFilesItem maps matched and unmatched items', () {
      expect(
        syncKeyForFilesItem(
          accountId: 'acc1',
          externalId: '101',
          isEpisode: false,
        ),
        'tmdb:movie:101',
      );
      expect(
        syncKeyForFilesItem(
          accountId: 'acc1',
          externalId: '101-2-3',
          isEpisode: true,
        ),
        'tmdb:ep:101:2:3',
      );
      expect(
        syncKeyForFilesItem(
          accountId: 'acc1',
          externalId: 'f9876543210abcdef',
          isEpisode: false,
        ),
        'file:acc1:9876543210abcdef',
      );
      // Provisional keys return null
      expect(
        syncKeyForFilesItem(
          accountId: 'acc1',
          externalId: 'p0123456789abcdef',
          isEpisode: false,
        ),
        isNull,
      );
      // Malformed keys return null
      expect(
        syncKeyForFilesItem(
          accountId: 'acc1',
          externalId: 'invalid-id-xyz',
          isEpisode: false,
        ),
        isNull,
      );
    });
  });

  for (final storeType in ['InMemoryPeerSyncStore', 'HivePeerSyncStore']) {
    group('$storeType - LWW and sync semantics', () {
      late PeerSyncStore store;
      Directory? tempDir;
      Box<Map<dynamic, dynamic>>? box;

      setUp(() async {
        if (storeType == 'InMemoryPeerSyncStore') {
          store = InMemoryPeerSyncStore();
        } else {
          tempDir = await Directory.systemTemp.createTemp('hive_peer_sync_');
          Hive.init(tempDir!.path);
          box = await Hive.openBox<Map<dynamic, dynamic>>(
            'peer_sync_test_${DateTime.now().microsecondsSinceEpoch}',
          );
          store = HivePeerSyncStore(box!);
        }
      });

      tearDown(() async {
        if (box != null) {
          await box!.deleteFromDisk();
          await Hive.close();
        }
        if (tempDir != null && tempDir!.existsSync()) {
          await tempDir!.delete(recursive: true);
        }
      });

      test('unwatched_clears_ninety_five_percent_position', () async {
        const key = 'tmdb:movie:201';
        // Progress at 950s / 1000s (95%) with watched threshold at 0.90
        final progressRecord = await store.recordProgress(
          key,
          positionSeconds: 950,
          durationSeconds: 1000,
          watchedFraction: 0.90,
          nowMs: 1000,
        );

        expect(progressRecord.watched, isTrue);
        expect(progressRecord.positionSeconds, 950);
        expect(progressRecord.durationSeconds, 1000);
        expect(progressRecord.updatedAt, 1000);

        final unwatchedRecord = await store.setWatched(
          key,
          false,
          nowMs: 2000,
        );

        expect(unwatchedRecord.watched, isFalse);
        expect(unwatchedRecord.positionSeconds, isNull);
        expect(unwatchedRecord.durationSeconds, isNull);
        expect(unwatchedRecord.updatedAt, 2000);

        final fetched = store.watchRecord(key);
        expect(fetched, equals(unwatchedRecord));
      });

      test('remote_unwatched_beats_older_local_watched_position', () async {
        const key = 'tmdb:movie:202';
        await store.recordProgress(
          key,
          positionSeconds: 800,
          durationSeconds: 1000,
          watchedFraction: 0.90,
          nowMs: 1000,
        );

        final remote = WireWatchRecord(
          key: key,
          watched: false,
          positionSeconds: null,
          durationSeconds: null,
          updatedAtMs: PlatformInt64Util.from(2000),
        );

        final mergeResult = await store.mergeRemote(
          watchRecords: [remote],
          pinRecords: const [],
          nowMs: 2100,
        );

        expect(mergeResult.changedWatchKeys, contains(key));
        final local = store.watchRecord(key);
        expect(local, isNotNull);
        expect(local!.watched, isFalse);
        expect(local.positionSeconds, isNull);
        expect(local.updatedAt, 2000);
      });

      test('stale_remote_record_is_ignored', () async {
        const key = 'tmdb:movie:203';
        await store.recordProgress(
          key,
          positionSeconds: 500,
          durationSeconds: 1000,
          watchedFraction: 0.90,
          nowMs: 1000,
        );

        final staleRemote = WireWatchRecord(
          key: key,
          watched: false,
          positionSeconds: null,
          durationSeconds: null,
          updatedAtMs: PlatformInt64Util.from(500),
        );

        final mergeResult = await store.mergeRemote(
          watchRecords: [staleRemote],
          pinRecords: const [],
          nowMs: 1500,
        );

        expect(mergeResult.changedWatchKeys, isEmpty);
        final local = store.watchRecord(key);
        expect(local, isNotNull);
        expect(local!.positionSeconds, 500);
        expect(local.updatedAt, 1000);
      });

      test('clamps_future_updated_at_to_now_plus_60s', () async {
        const key = 'tmdb:movie:204';
        const nowMs = 100000;

        final skewedRemote = WireWatchRecord(
          key: key,
          watched: true,
          positionSeconds: null,
          durationSeconds: null,
          updatedAtMs: PlatformInt64Util.from(nowMs + 3600000),
        );

        final mergeResult = await store.mergeRemote(
          watchRecords: [skewedRemote],
          pinRecords: const [],
          nowMs: nowMs,
        );

        expect(mergeResult.changedWatchKeys, contains(key));
        final stored = store.watchRecord(key);
        expect(stored, isNotNull);
        expect(stored!.updatedAt, nowMs + 60000);

        // A subsequent local write at nowMs + 60_001 beats it
        final localWin = await store.setWatched(
          key,
          false,
          nowMs: nowMs + 60001,
        );
        expect(localWin.watched, isFalse);
        expect(store.watchRecord(key)!.watched, isFalse);
      });

      test('landed_at_advances_monotonically_for_old_origin_timestamps',
          () async {
        const key = 'tmdb:movie:205';

        final oldRemote = WireWatchRecord(
          key: key,
          watched: true,
          positionSeconds: null,
          durationSeconds: null,
          updatedAtMs: PlatformInt64Util.from(100),
        );

        await store.mergeRemote(
          watchRecords: [oldRemote],
          pinRecords: const [],
          nowMs: 5000,
        );

        final record = store.watchRecord(key);
        expect(record, isNotNull);
        expect(record!.landedAt, 5000);

        final since4000 = store.watchRecordsSince(4000);
        expect(since4000.map((r) => r.key), contains(key));

        final since5000 = store.watchRecordsSince(5000);
        expect(since5000.map((r) => r.key), isNot(contains(key)));
      });

      test('roster_merge_prefers_higher_updated_at_and_revoked_on_tie',
          () async {
        const nodeId = 'node-delta-789';

        await store.putMember(
          const PeerMember(
            nodeId: nodeId,
            deviceName: 'Harbor Deck',
            platform: 'linux',
            updatedAt: 1000,
            revoked: false,
          ),
        );

        // Merging revoked: true with same updatedAt (1000) keeps revoked: true
        final changed = await store.mergeRoster(
          [
            const PeerMember(
              nodeId: nodeId,
              deviceName: 'Harbor Deck',
              platform: 'linux',
              updatedAt: 1000,
              revoked: true,
            ),
          ],
          nowMs: 1500,
        );

        expect(changed, contains(nodeId));
        expect(store.member(nodeId)!.revoked, isTrue);

        // Attempting to un-revoke with same or older updatedAt fails
        final ignored = await store.mergeRoster(
          [
            const PeerMember(
              nodeId: nodeId,
              deviceName: 'Harbor Deck',
              platform: 'linux',
              updatedAt: 1000,
              revoked: false,
            ),
          ],
          nowMs: 1600,
        );
        expect(ignored, isEmpty);
        expect(store.member(nodeId)!.revoked, isTrue);

        // Higher updatedAt un-revokes
        final revived = await store.mergeRoster(
          [
            const PeerMember(
              nodeId: nodeId,
              deviceName: 'Harbor Deck',
              platform: 'linux',
              updatedAt: 2000,
              revoked: false,
            ),
          ],
          nowMs: 2500,
        );
        expect(revived, contains(nodeId));
        expect(store.member(nodeId)!.revoked, isFalse);
      });
    });
  }

  group('HivePeerSyncStore persistence', () {
    test('hive_store_persists_across_reopen', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('hive_reopen_test_');
      Hive.init(tempDir.path);

      const boxName = 'peer_sync_reopen_test';
      var box = await Hive.openBox<Map<dynamic, dynamic>>(boxName);
      var store = HivePeerSyncStore(box);

      // Write watch record
      await store.recordProgress(
        'tmdb:movie:301',
        positionSeconds: 120,
        durationSeconds: 1000,
        watchedFraction: 0.90,
        nowMs: 1000,
      );

      // Write pin record
      await store.setPin(
        groupKey: 'harbor-of-echoes',
        isShow: true,
        tmdbId: 550,
        pinned: true,
        nowMs: 1100,
      );

      // Write roster member
      await store.putMember(
        const PeerMember(
          nodeId: 'node-reopen-1',
          deviceName: 'Echo Tablet',
          platform: 'android',
          updatedAt: 1200,
        ),
      );

      // Write watermark
      await store.setWatermark(
        'node-reopen-1',
        const PeerWatermark(
          lastSentLandedAt: 1000,
          lastPeerNowMs: 2000,
          lastSyncedAt: 3000,
        ),
      );

      // Mark seeded
      await store.markSeeded();

      // Close box
      await box.close();

      // Reopen box and create a new HivePeerSyncStore instance
      box = await Hive.openBox<Map<dynamic, dynamic>>(boxName);
      store = HivePeerSyncStore(box);

      // Verify all data is read back synchronously
      final watch = store.watchRecord('tmdb:movie:301');
      expect(watch, isNotNull);
      expect(watch!.positionSeconds, 120);
      expect(watch.updatedAt, 1000);

      final pin = store.pinRecord(
        isShow: true,
        groupKey: 'harbor-of-echoes',
      );
      expect(pin, isNotNull);
      expect(pin!.tmdbId, 550);
      expect(pin.pinned, isTrue);

      final member = store.member('node-reopen-1');
      expect(member, isNotNull);
      expect(member!.deviceName, 'Echo Tablet');

      final mark = store.watermark('node-reopen-1');
      expect(mark, isNotNull);
      expect(mark!.lastSentLandedAt, 1000);
      expect(mark.lastPeerNowMs, 2000);
      expect(mark.lastSyncedAt, 3000);

      expect(store.isSeeded, isTrue);

      // LandedAt sequence continues monotonically after reopen
      final nextRec = await store.setWatched(
        'tmdb:movie:302',
        true,
        nowMs: 500, // origin timestamp is older than previous landedAt (1100)
      );
      expect(nextRec.landedAt, greaterThan(pin.landedAt));

      await box.deleteFromDisk();
      await Hive.close();
      await tempDir.delete(recursive: true);
    });
  });
}
