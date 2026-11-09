import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/cache/invalidation_target.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/player/progress_service.dart';
import 'package:player/core/sources/cache/source_rules.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_media_source.dart';
import 'package:player/core/sources/files/files_ids.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/match/file_matcher.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';

import 'fake_backend.dart';
import 'fake_media_names.dart';
import 'files_fixture.dart';

class _CapturingRelay extends RelayTmdb {
  final searched = <String>[];
  bool searchDown = false;

  @override
  Future<List<TmdbCandidate>> searchMovies(String query, {int? year}) async {
    searched.add('movie:$query');
    if (searchDown) throw RelayUnavailable('search is down');
    return const [];
  }

  @override
  Future<List<TmdbCandidate>> searchShows(String query, {int? year}) async {
    searched.add('show:$query');
    if (searchDown) throw RelayUnavailable('search is down');
    return const [];
  }

  @override
  Future<MatchedMovie> movie(int id) async {
    return MatchedMovie(
      tmdbId: id,
      title: 'Fable of Glass',
      year: 2031,
    );
  }

  @override
  Future<MatchedShow> show(int id, {required Iterable<int> seasons}) async {
    return MatchedShow(
      tmdbId: id,
      title: 'Glass Orchard',
      year: 2021,
    );
  }
}

Source _makeSource(String accountId) {
  return Source(
    account: ProviderAccount(
      id: accountId,
      kind: SourceKind.files,
      displayName: 'Files $accountId',
      storageNamespace: 'source/$accountId',
      activeProfileId: kOwnerProfileId,
    ),
    profile: SourceProfile(
      id: kOwnerProfileId,
      accountId: accountId,
      name: 'Owner',
      isOwner: true,
    ),
    server: SourceServer(
      id: accountId,
      accountId: accountId,
      profileId: kOwnerProfileId,
      name: 'Files $accountId',
    ),
  );
}

void main() {
  group('Files PeerSync integration', () {
    test('seeds_existing_watched_progress_and_pins_on_first_open', () async {
      final dir = await Directory.systemTemp.createTemp('peer_sync_seed_test');
      Hive.init(dir.path);
      addTearDown(() async {
        await Hive.close();
        await dir.delete(recursive: true);
      });

      final indexBox =
          await Hive.openBox<Map<dynamic, dynamic>>('files_index_seed');
      final index = FileLibraryIndex(indexBox, accountId: kFilesLocalAccountId);
      await index.setWatched('99901', true);
      await index.putGroup(GroupMatch(
        groupKey: 'fable of glass:2031',
        isShow: false,
        tmdbId: 99901,
        pinned: true,
        matchedAt: DateTime.now(),
      ));

      final progressStore = InMemoryPlaybackProgressStore();
      await progressStore.save(LocalPlaybackProgress(
        sourceId: 'flocal:owner:local',
        mediaId: '99902-1-1',
        mediaType: 'episode',
        positionSeconds: 120,
        durationSeconds: 1800,
        updatedAt: DateTime.now(),
      ));

      final syncStore = InMemoryPeerSyncStore();
      expect(syncStore.isSeeded, isFalse);

      await seedPeerSyncStoreIfNeeded(
        syncStore: syncStore,
        indexBox: indexBox,
        progressStore: progressStore,
      );

      expect(syncStore.isSeeded, isTrue);

      final movieRec = syncStore.watchRecord('tmdb:movie:99901');
      expect(movieRec, isNotNull);
      expect(movieRec!.watched, isTrue);

      final epRec = syncStore.watchRecord('tmdb:ep:99902:1:1');
      expect(epRec, isNotNull);
      expect(epRec!.positionSeconds, 120);
      expect(epRec.durationSeconds, 1800);

      final pinRec =
          syncStore.pinRecord(isShow: false, groupKey: 'fable of glass:2031');
      expect(pinRec, isNotNull);
      expect(pinRec!.pinned, isTrue);
      expect(pinRec.tmdbId, 99901);
    });

    test('matched_watch_state_shared_across_files_sources', () async {
      final dir = await Directory.systemTemp.createTemp('files_sync_shared');
      Hive.init(dir.path);
      addTearDown(() async {
        await Hive.close();
        await dir.delete(recursive: true);
      });

      final box1 = await Hive.openBox<Map<dynamic, dynamic>>('index_flocal');
      final box2 = await Hive.openBox<Map<dynamic, dynamic>>('index_other');
      final index1 = FileLibraryIndex(box1, accountId: kFilesLocalAccountId);
      final index2 = FileLibraryIndex(box2, accountId: 's0123456789abcdef');

      const root1 = LibraryRoot(
        id: 'r1',
        path: '/media/movies1',
        kind: FilesLibraryKind.movies,
        title: 'Movies 1',
      );
      const root2 = LibraryRoot(
        id: 'r2',
        path: '/media/movies2',
        kind: FilesLibraryKind.movies,
        title: 'Movies 2',
      );
      await index1.putRoot(root1);
      await index2.putRoot(root2);

      const movie99901 = MatchedMovie(
        tmdbId: 99901,
        title: 'Fable of Glass',
        year: 2031,
      );
      await index1.putMovie(movie99901);
      await index2.putMovie(movie99901);

      final group99901 = GroupMatch(
        groupKey: 'fable of glass:2031',
        isShow: false,
        tmdbId: 99901,
        matchedAt: filesT0,
      );
      await index1.putGroup(group99901);
      await index2.putGroup(group99901);

      final file1 = IndexedFile(
        key: 'file99901_1',
        rootId: 'r1',
        path: 'Fable of Glass (2031).mkv',
        size: 500,
        modified: filesT0,
        firstSeen: filesT0,
        parsed: const ParsedName(
          path: 'Fable of Glass (2031).mkv',
          groupKey: 'fable of glass:2031',
          title: 'Fable of Glass',
          year: 2031,
          isEpisode: false,
        ),
      );
      final file2 = IndexedFile(
        key: 'file99901_2',
        rootId: 'r2',
        path: 'Fable of Glass (2031).mkv',
        size: 500,
        modified: filesT0,
        firstSeen: filesT0,
        parsed: const ParsedName(
          path: 'Fable of Glass (2031).mkv',
          groupKey: 'fable of glass:2031',
          title: 'Fable of Glass',
          year: 2031,
          isEpisode: false,
        ),
      );
      await index1.putFiles([file1]);
      await index2.putFiles([file2]);

      final syncStore = InMemoryPeerSyncStore();
      final invalidated1 = <InvalidationTarget>[];
      final invalidated2 = <InvalidationTarget>[];

      final source1 = filesLocalSource;
      final source2 = _makeSource('s0123456789abcdef');

      final media1 = FilesMediaSource(
        source: source1,
        backend: FakeBackend(const {}),
        index: index1,
        progress: InMemoryPlaybackProgressStore(),
        matcher: FileMatcher(
          tmdb: FakeFilesRelay(),
          names: FakeMediaNames(),
          index: index1,
          progress: InMemoryPlaybackProgressStore(),
          sourceId: source1.id,
          syncStore: syncStore,
        ),
        tmdb: FakeFilesRelay(),
        syncStore: syncStore,
        invalidate: (targets) async => invalidated1.addAll(targets),
      );
      addTearDown(media1.dispose);

      final media2 = FilesMediaSource(
        source: source2,
        backend: FakeBackend(const {}),
        index: index2,
        progress: InMemoryPlaybackProgressStore(),
        matcher: FileMatcher(
          tmdb: FakeFilesRelay(),
          names: FakeMediaNames(),
          index: index2,
          progress: InMemoryPlaybackProgressStore(),
          sourceId: source2.id,
          syncStore: syncStore,
        ),
        tmdb: FakeFilesRelay(),
        syncStore: syncStore,
        invalidate: (targets) async => invalidated2.addAll(targets),
      );
      addTearDown(media2.dispose);

      final ref2 = ItemRef(
        sourceId: source2.id,
        kind: ItemKind.movie,
        externalId: '99901',
      );
      final before = await media2.item(ref2);
      expect(before.summary.userState.watched, isFalse);

      final ref1 = ItemRef(
        sourceId: source1.id,
        kind: ItemKind.movie,
        externalId: '99901',
      );
      await media1.setWatched(ref1, true);

      final after = await media2.item(ref2);
      expect(after.summary.userState.watched, isTrue);

      expect(invalidated1, containsAll(SourceRules.watchedChanged(source1.id)));
      expect(invalidated2, containsAll(SourceRules.watchedChanged(source2.id)));
    });

    test('remove_from_continue_watching_clears_synced_position_across_sources',
        () async {
      final dir = await Directory.systemTemp.createTemp('files_sync_cw_test');
      Hive.init(dir.path);
      addTearDown(() async {
        await Hive.close();
        await dir.delete(recursive: true);
      });

      final box1 = await Hive.openBox<Map<dynamic, dynamic>>('index_cw_1');
      final box2 = await Hive.openBox<Map<dynamic, dynamic>>('index_cw_2');
      final index1 = FileLibraryIndex(box1, accountId: kFilesLocalAccountId);
      final index2 = FileLibraryIndex(box2, accountId: 's0123456789abcdef');

      const root1 = LibraryRoot(
        id: 'r1',
        path: '/media/movies1',
        kind: FilesLibraryKind.movies,
        title: 'Movies 1',
      );
      const root2 = LibraryRoot(
        id: 'r2',
        path: '/media/movies2',
        kind: FilesLibraryKind.movies,
        title: 'Movies 2',
      );
      await index1.putRoot(root1);
      await index2.putRoot(root2);

      const movie99901 = MatchedMovie(
        tmdbId: 99901,
        title: 'Fable of Glass',
        year: 2031,
      );
      await index1.putMovie(movie99901);
      await index2.putMovie(movie99901);

      final group99901 = GroupMatch(
        groupKey: 'fable of glass:2031',
        isShow: false,
        tmdbId: 99901,
        matchedAt: filesT0,
      );
      await index1.putGroup(group99901);
      await index2.putGroup(group99901);

      final file1 = IndexedFile(
        key: 'file99901_1',
        rootId: 'r1',
        path: 'Fable of Glass (2031).mkv',
        size: 500,
        modified: filesT0,
        firstSeen: filesT0,
        parsed: const ParsedName(
          path: 'Fable of Glass (2031).mkv',
          groupKey: 'fable of glass:2031',
          title: 'Fable of Glass',
          year: 2031,
          isEpisode: false,
        ),
      );
      final file2 = IndexedFile(
        key: 'file99901_2',
        rootId: 'r2',
        path: 'Fable of Glass (2031).mkv',
        size: 500,
        modified: filesT0,
        firstSeen: filesT0,
        parsed: const ParsedName(
          path: 'Fable of Glass (2031).mkv',
          groupKey: 'fable of glass:2031',
          title: 'Fable of Glass',
          year: 2031,
          isEpisode: false,
        ),
      );
      await index1.putFiles([file1]);
      await index2.putFiles([file2]);

      final syncStore = InMemoryPeerSyncStore();
      final source1 = filesLocalSource;
      final source2 = _makeSource('s0123456789abcdef');

      final media1 = FilesMediaSource(
        source: source1,
        backend: FakeBackend(const {}),
        index: index1,
        progress: InMemoryPlaybackProgressStore(),
        matcher: FileMatcher(
          tmdb: FakeFilesRelay(),
          names: FakeMediaNames(),
          index: index1,
          progress: InMemoryPlaybackProgressStore(),
          sourceId: source1.id,
          syncStore: syncStore,
        ),
        tmdb: FakeFilesRelay(),
        syncStore: syncStore,
      );
      addTearDown(media1.dispose);

      final media2 = FilesMediaSource(
        source: source2,
        backend: FakeBackend(const {}),
        index: index2,
        progress: InMemoryPlaybackProgressStore(),
        matcher: FileMatcher(
          tmdb: FakeFilesRelay(),
          names: FakeMediaNames(),
          index: index2,
          progress: InMemoryPlaybackProgressStore(),
          sourceId: source2.id,
          syncStore: syncStore,
        ),
        tmdb: FakeFilesRelay(),
        syncStore: syncStore,
      );
      addTearDown(media2.dispose);

      // Record a 300s/3600s position for 99901 in syncStore
      await syncStore.recordProgress(
        'tmdb:movie:99901',
        positionSeconds: 300,
        durationSeconds: 3600,
        watchedFraction: ProgressService.watchedThreshold,
        nowMs: 1000,
      );

      final cw1 = await media1.continueWatching();
      final cw2 = await media2.continueWatching();
      expect(cw1.map((i) => i.ref.externalId), contains('99901'));
      expect(cw2.map((i) => i.ref.externalId), contains('99901'));

      final ref1 = ItemRef(
        sourceId: source1.id,
        kind: ItemKind.movie,
        externalId: '99901',
      );
      await media1.removeFromContinueWatching(ref1);

      final cw1After = await media1.continueWatching();
      final cw2After = await media2.continueWatching();
      expect(cw1After, isEmpty);
      expect(cw2After, isEmpty);
    });

    test('matcher_applies_synced_pin_from_peer_sync_store_on_scan', () async {
      final dir = await Directory.systemTemp.createTemp('files_sync_pin_test');
      Hive.init(dir.path);
      addTearDown(() async {
        await Hive.close();
        await dir.delete(recursive: true);
      });

      final box = await Hive.openBox<Map<dynamic, dynamic>>('index_pin');
      final index = FileLibraryIndex(box, accountId: kFilesLocalAccountId);

      const root = LibraryRoot(
        id: 'r1',
        path: '/media/movies',
        kind: FilesLibraryKind.movies,
        title: 'Movies',
      );
      await index.putRoot(root);

      final file = IndexedFile(
        key: 'file_glass',
        rootId: 'r1',
        path: 'Fable of Glass (2031).mkv',
        size: 500,
        modified: filesT0,
        firstSeen: filesT0,
        parsed: const ParsedName(
          path: 'Fable of Glass (2031).mkv',
          groupKey: 'fable of glass:2031',
          title: 'Fable of Glass',
          year: 2031,
          isEpisode: false,
        ),
      );
      await index.putFiles([file]);

      final syncStore = InMemoryPeerSyncStore();
      await syncStore.setPin(
        groupKey: 'fable of glass:2031',
        isShow: false,
        tmdbId: 99901,
        pinned: true,
        nowMs: 5000,
      );

      final relay = _CapturingRelay();
      relay.searchDown = true; // Search would fail if called

      final matcher = FileMatcher(
        tmdb: relay,
        names: FakeMediaNames(),
        index: index,
        progress: InMemoryPlaybackProgressStore(),
        sourceId: filesLocalSource.id,
        syncStore: syncStore,
      );

      await matcher.matchPending();

      final group = index.group('fable of glass:2031');
      expect(group, isNotNull);
      expect(group!.pinned, isTrue);
      expect(group.tmdbId, 99901);
      expect(relay.searched, isEmpty);
    });

    group('pins and migrations', () {
      const groupKey = 'fable of glass:2031';

      Future<FileLibraryIndex> openIndex(String name) async {
        final dir = await Directory.systemTemp.createTemp(name);
        Hive.init(dir.path);
        addTearDown(() async {
          await Hive.close();
          await dir.delete(recursive: true);
        });
        final box = await Hive.openBox<Map<dynamic, dynamic>>(name);
        final index = FileLibraryIndex(box, accountId: kFilesLocalAccountId);
        await index.putRoot(const LibraryRoot(
          id: 'r1',
          path: '/media/movies',
          kind: FilesLibraryKind.movies,
          title: 'Movies',
        ));
        await index.putFiles([
          IndexedFile(
            key: 'file_glass',
            rootId: 'r1',
            path: 'Fable of Glass (2031).mkv',
            size: 500,
            modified: filesT0,
            firstSeen: filesT0,
            parsed: const ParsedName(
              path: 'Fable of Glass (2031).mkv',
              groupKey: groupKey,
              title: 'Fable of Glass',
              year: 2031,
              isEpisode: false,
            ),
          ),
        ]);
        return index;
      }

      FileMatcher matcherOver(
        FileLibraryIndex index,
        PeerSyncStore syncStore, {
        PlaybackProgressStore? progress,
      }) =>
          FileMatcher(
            tmdb: _CapturingRelay()..searchDown = true,
            names: FakeMediaNames(),
            index: index,
            progress: progress ?? InMemoryPlaybackProgressStore(),
            sourceId: filesLocalSource.id,
            syncStore: syncStore,
          );

      test('a_pin_older_than_the_automatic_match_is_still_applied', () async {
        final index = await openIndex('pin_before_match');
        // Matched automatically after the pin was made on the other device.
        await index.putGroup(GroupMatch(
          groupKey: groupKey,
          isShow: false,
          tmdbId: 1,
          matchedAt: DateTime.fromMillisecondsSinceEpoch(9000),
        ));
        final syncStore = InMemoryPeerSyncStore();
        await syncStore.setPin(
          groupKey: groupKey,
          isShow: false,
          tmdbId: 99901,
          pinned: true,
          nowMs: 5000,
        );

        await matcherOver(index, syncStore).matchPending();

        final group = index.group(groupKey)!;
        expect(group.pinned, isTrue);
        expect(group.tmdbId, 99901);
        expect(group.pinRevision, 5000);
      });

      test('a_stored_unpin_is_applied_when_the_source_scans', () async {
        final index = await openIndex('stored_unpin');
        await index.putGroup(GroupMatch(
          groupKey: groupKey,
          isShow: false,
          tmdbId: 99901,
          pinned: true,
          matchedAt: DateTime.fromMillisecondsSinceEpoch(1000),
          pinRevision: 4000,
        ));
        final syncStore = InMemoryPeerSyncStore();
        await syncStore.setPin(
          groupKey: groupKey,
          isShow: false,
          tmdbId: 99901,
          pinned: false,
          nowMs: 5000,
        );

        await matcherOver(index, syncStore).matchPending();

        final group = index.group(groupKey)!;
        expect(group.pinned, isFalse);
        expect(group.pinRevision, 5000);
      });

      test('a_newer_local_pin_survives_an_older_stored_unpin', () async {
        final index = await openIndex('newer_local_pin');
        await index.putGroup(GroupMatch(
          groupKey: groupKey,
          isShow: false,
          tmdbId: 99901,
          pinned: true,
          matchedAt: DateTime.fromMillisecondsSinceEpoch(1000),
          pinRevision: 6000,
        ));
        final syncStore = InMemoryPeerSyncStore();
        await syncStore.setPin(
          groupKey: groupKey,
          isShow: false,
          tmdbId: 99901,
          pinned: false,
          nowMs: 5000,
        );

        await matcherOver(index, syncStore).matchPending();

        expect(index.group(groupKey)!.pinned, isTrue);
      });

      test('a_cleared_record_replaces_the_older_one_at_the_destination',
          () async {
        final index = await openIndex('cleared_migration');
        await index.putGroup(GroupMatch(
          groupKey: groupKey,
          isShow: false,
          tmdbId: 1,
          matchedAt: filesT0,
        ));
        final syncStore = InMemoryPeerSyncStore();
        await syncStore.setWatched('tmdb:movie:2', true, nowMs: 3000);
        // Marked unwatched later, under the id the group had before.
        await syncStore.setWatched('tmdb:movie:1', false, nowMs: 4000);

        await matcherOver(index, syncStore)
            .pin(groupKey, isShow: false, tmdbId: 2);

        expect(syncStore.watchRecord('tmdb:movie:2')!.watched, isFalse);
      });

      test('provisional_progress_moves_into_the_sync_record_on_match',
          () async {
        final index = await openIndex('provisional_migration');
        final progress = InMemoryPlaybackProgressStore();
        await progress.save(LocalPlaybackProgress(
          sourceId: filesLocalSource.id.value,
          mediaId: movieId(provisionalKey(groupKey)),
          mediaType: 'movie',
          positionSeconds: 120,
          durationSeconds: 1800,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
        ));
        final syncStore = InMemoryPeerSyncStore();

        await matcherOver(index, syncStore, progress: progress)
            .pin(groupKey, isShow: false, tmdbId: 99901);

        final record = syncStore.watchRecord('tmdb:movie:99901');
        expect(record, isNotNull);
        expect(record!.positionSeconds, 120);
        expect(record.durationSeconds, 1800);
      });

      Future<FilesMediaSource> mediaOver(
        FileLibraryIndex index,
        PeerSyncStore syncStore, {
        Source? source,
        List<InvalidationTarget>? invalidated,
      }) async {
        final s = source ?? filesLocalSource;
        await index.putMovie(const MatchedMovie(
          tmdbId: 99901,
          title: 'Fable of Glass',
          year: 2031,
        ));
        await index.putGroup(GroupMatch(
          groupKey: groupKey,
          isShow: false,
          tmdbId: 99901,
          matchedAt: filesT0,
        ));
        final media = FilesMediaSource(
          source: s,
          backend: FakeBackend(const {}),
          index: index,
          progress: InMemoryPlaybackProgressStore(),
          matcher: matcherOver(index, syncStore),
          tmdb: FakeFilesRelay(),
          syncStore: syncStore,
          invalidate: (targets) async => invalidated?.addAll(targets),
        );
        addTearDown(media.dispose);
        return media;
      }

      ItemRef movieRef(Source s) => ItemRef(
            sourceId: s.id,
            kind: ItemKind.movie,
            externalId: '99901',
          );

      test('resume_follows_the_synced_watched_state_not_a_legacy_flag',
          () async {
        final index = await openIndex('resume_sync_state');
        // A legacy flag from before sync, on an item marked unwatched since.
        await index.setWatched('99901', true);
        final syncStore = InMemoryPeerSyncStore();
        await syncStore.recordProgress(
          'tmdb:movie:99901',
          positionSeconds: 600,
          durationSeconds: 3000,
          watchedFraction: 0.95,
          nowMs: 2000,
        );
        final media = await mediaOver(index, syncStore);

        final detail = await media.item(movieRef(filesLocalSource));
        expect(detail.summary.userState.progressSeconds, 600);

        // Watched in the synced record, with no legacy flag.
        await index.setWatched('99901', false);
        await syncStore.setWatched('tmdb:movie:99901', true, nowMs: 3000);
        final watched = await media.item(movieRef(filesLocalSource));
        expect(watched.summary.userState.progressSeconds, isNull);
      });

      test('invalidating_a_shared_item_refreshes_every_files_source', () async {
        final syncStore = InMemoryPeerSyncStore();
        final first = <InvalidationTarget>[];
        final second = <InvalidationTarget>[];
        final otherSource = _makeSource('s0123456789abcdef');
        final media1 = await mediaOver(
          await openIndex('invalidate_first'),
          syncStore,
          invalidated: first,
        );
        final media2 = await mediaOver(
          await openIndex('invalidate_second'),
          syncStore,
          source: otherSource,
          invalidated: second,
        );

        await media1.invalidateWatchedFor(movieRef(filesLocalSource));

        expect(first, containsAll(SourceRules.watchedChanged(media1.id)));
        expect(second, containsAll(SourceRules.watchedChanged(media2.id)));
      });
    });
  });
}
