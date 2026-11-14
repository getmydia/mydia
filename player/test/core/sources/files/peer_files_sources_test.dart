import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_files_backend.dart';
import 'package:player/core/p2p/peer_files_host.dart'
    show peerFilesRevisionsProvider;
import 'package:player/core/p2p/peer_files_wire.dart';
import 'package:player/core/p2p/peer_sync_records.dart';
import 'package:player/core/p2p/peer_sync_service.dart'
    show applyRemoteFilesChanges;
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_ids.dart';
import 'package:player/core/sources/files/files_media_source.dart';
import 'package:player/core/sources/files/files_scan_controller.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/peer_files_sources.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/domain/sources/item.dart';

import '../../../test_utils/no_downloads.dart';
import '../../p2p/fake_peer_files.dart';
import 'fake_backend.dart';
import 'files_fixture.dart';
import 'peer_files_harness.dart';

Future<void> _settle() async {
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late PeerHarness h;

  setUp(() async {
    h = PeerHarness(await FilesFixture.create());
    await h.seed();
  });

  Future<ProviderContainer> container() async {
    final c = await h.container();
    addTearDown(c.dispose);
    return c;
  }

  test('isPeerFilesSource matches only lent accounts', () {
    expect(isPeerFilesSource(filesLocalSource), isFalse);
    expect(isPeerFilesSource(peerFilesSource(lentFlocal())), isTrue);
    expect(peerFilesHostAccountId(peerLocalId), kFilesLocalAccountId);
  });

  test('peer_sources_follow_client_accounts', () async {
    final c = await container();
    expect(c.read(sourcesProvider).map((s) => s.account.id),
        [kFilesLocalAccountId]);

    h.client.list.value = [lentFlocal()];
    final peer = c.read(sourcesProvider).last;
    expect(peer.account.id, peerLocalId);
    expect(peer.kind, SourceKind.files);
    expect(peer.displayName, 'Den Desktop · Folders');

    h.client.list.value = [lentFlocal(name: 'Films')];
    expect(c.read(sourcesProvider).last.displayName, 'Den Desktop · Films');
  });

  test('peer_and_local_flocal_coexist', () async {
    h.client.list.value = [lentFlocal()];
    final c = await container();
    final ids = c.read(sourcesProvider).map((s) => s.id).toList();
    expect(ids, hasLength(2));
    expect(ids.toSet(), hasLength(2));

    final local =
        c.read(mediaSourceProvider(filesLocalSource.id))! as FilesMediaSource;
    final peer = c.read(mediaSourceProvider(ids.last))! as FilesMediaSource;
    expect(local.index.roots().map((r) => r.id), [FilesFixture.rootId]);
    expect(peer.index.roots().map((r) => r.id), ['rhost']);
    expect(peer.index.files().keys,
        isNot(anyElement(isIn(local.index.files().keys))));
    expect(local.index.files().keys,
        isNot(anyElement(isIn(peer.index.files().keys))));
    expect(peer.syncAccountId, kFilesLocalAccountId);
    expect(local.syncAccountId, kFilesLocalAccountId);
  });

  test('a peer source offers no match edits and no downloads', () async {
    h.client.list.value = [lentFlocal()];
    final c = await container();
    final peerId = c.read(sourcesProvider).last.id;
    final peer = c.read(mediaSourceProvider(peerId))! as FilesMediaSource;
    final ref = ItemRef(
        sourceId: peerId, kind: ItemKind.movie, externalId: tmdbBase(301));
    expect(peer.canEditMatch(ref), isFalse);
    expect(peer.as<Downloadable>(), isNull);
  });

  test('peer_source_uses_host_account_for_sync_keys', () async {
    h.client.list.value = [lentFlocal()];
    final c = await container();
    final peerId = c.read(sourcesProvider).last.id;
    final peer = c.read(mediaSourceProvider(peerId))! as FilesMediaSource;
    final key = fileKeyFor('rhost', 'clips/beach day.mkv');

    await peer.setWatched(
        ItemRef(
            sourceId: peerId,
            kind: ItemKind.video,
            externalId: unmatchedFileId(key)),
        true);

    final record = h.syncStore
        .watchRecord(unmatchedFileSyncKey(kFilesLocalAccountId, key));
    expect(record?.watched, isTrue);
    expect(h.syncStore.watchRecord(unmatchedFileSyncKey(peerLocalId, key)),
        isNull);
    expect(peer.index.watched(), isEmpty,
        reason: 'nothing is written into the lent index');
  });

  test('peer_source_never_scans', () async {
    h.client.list.value = [lentFlocal()];
    final c = await container();
    final peerId = c.read(sourcesProvider).last.id;
    expect(c.read(mediaSourceProvider(peerId)), isA<FilesMediaSource>());
    await _settle();
    expect(c.exists(filesScanProvider(peerId)), isFalse);
    final peerBackend =
        h.backends.entries.where((e) => isPeerFilesSource(e.key)).single.value;
    expect(peerBackend.listed, isEmpty);

    // Asked anyway, it does nothing.
    await c.read(filesScanProvider(peerId).notifier).rescan();
    expect(peerBackend.listed, isEmpty);
    expect(h.store.index(peerLocalId).roots().map((r) => r.id), ['rhost']);
  });

  test('a copy that lands after its manifest entry rebuilds the source on it',
      () async {
    h.client.list.value = [lentFlocal()];
    final c = await container();
    final peerId = c.read(sourcesProvider).last.id;
    final first = c.read(mediaSourceProvider(peerId))! as FilesMediaSource;
    expect(first.index.files(), hasLength(2));

    // The client publishes the new revision while its pages are still
    // being fetched, then the fetch lands with no further publish.
    h.client.list.value = [lentFlocal(revision: 2)];
    expect(c.read(mediaSourceProvider(peerId)), same(first));
    await h.host.removeFiles([fileKeyFor('rhost', 'clips/beach day.mkv')]);
    await h.store.replace(peerLocalId, 2, pageIndex(h.host));

    final second = c.read(mediaSourceProvider(peerId))! as FilesMediaSource;
    expect(identical(first, second), isFalse);
    expect(second.index, same(h.store.index(peerLocalId)));
    expect(second.index.files(), hasLength(1));
  });

  test('a play spanning a new copy still reports on the host account',
      () async {
    h.client.list.value = [lentFlocal()];
    final c = await container();
    final peerId = c.read(sourcesProvider).last.id;
    final playing = c.read(mediaSourceProvider(peerId))! as FilesMediaSource;
    final key = fileKeyFor('rhost', 'clips/beach day.mkv');
    final ref = ItemRef(
        sourceId: peerId,
        kind: ItemKind.video,
        externalId: unmatchedFileId(key));

    // The new copy drops the file being played, and the old generation's
    // records are deleted from the box.
    await h.host.removeFiles([key]);
    await h.store.replace(peerLocalId, 2, pageIndex(h.host));
    expect(c.read(mediaSourceProvider(peerId)), isNot(same(playing)));

    // What the playback reporter calls on the source it started with.
    expect(playing.currentRef(ref, key), ref);
    expect(playing.syncKeyFor(ref),
        unmatchedFileSyncKey(kFilesLocalAccountId, key));
    await playing.invalidateWatchedFor(ref);
    await playing.setWatched(ref, true);
    expect(
        h.syncStore
            .watchRecord(unmatchedFileSyncKey(kFilesLocalAccountId, key))
            ?.watched,
        isTrue);
  });

  test('remote pins and unpins never touch a lent index', () async {
    h.client.list.value = [lentFlocal()];
    final c = await container();
    final peerId = c.read(sourcesProvider).last.id;
    final peer = c.read(mediaSourceProvider(peerId))! as FilesMediaSource;
    final group = h.host
        .files()
        .values
        .firstWhere((f) => f.parsed != null)
        .parsed!
        .groupKey;
    final before = peer.index.group(group);
    final revisions = c.read(peerFilesRevisionsProvider);

    // A pin to "no match" needs no relay, so a writable matcher would
    // write it at once.
    final pin = await h.syncStore.setPin(
        groupKey: group, isShow: false, tmdbId: null, pinned: true, nowMs: 5);
    await applyRemoteFilesChanges(
      store: h.syncStore,
      sources: FilesMediaSource.activeSources.toList(),
      changedWatchKeys: const {},
      changedPinKeys: {pin.key},
    );
    await peer.matcher.applyRemotePin(group, isShow: false, pinRevision: 5);
    expect(peer.index.group(group), same(before));

    // An unpin on a copy where the host had pinned the group.
    await h.host.putGroup(before!.copyWith(pinned: true));
    await h.store.replace(peerLocalId, 2, pageIndex(h.host));
    final next = c.read(mediaSourceProvider(peerId))! as FilesMediaSource;
    final pinned = next.index.group(group);
    expect(pinned?.pinned, isTrue);
    final unpin = await h.syncStore.setPin(
        groupKey: group, isShow: false, tmdbId: null, pinned: false, nowMs: 6);
    await applyRemoteFilesChanges(
      store: h.syncStore,
      sources: FilesMediaSource.activeSources.toList(),
      changedWatchKeys: const {},
      changedPinKeys: {unpin.key},
    );
    expect(await next.matcher.applyRemoteUnpin(group, pinRevision: 6), isFalse);
    expect(next.index.group(group), same(pinned));

    expect(h.syncStore.allWatchRecords(), isEmpty);
    expect(revisions.revision(peerLocalId), 0);
    expect(revisions.revision(kFilesLocalAccountId), 0);
  });

  test('a host that lends nothing more lets its proxy target go', () async {
    h.client.list.value = [
      lentFlocal(),
      lentFlocal(accountId: 'w0123456789abcdef', name: 'Share'),
    ];
    final c = await container();
    expect(c.read(sourcesProvider), hasLength(3));
    final target = PeerFilesBackend.targetFor(hostNode);
    addTearDown(() => PeerFilesBackend.releaseHost(hostNode, () => h.proxy));
    await PeerFilesBackend(
      nodeId: hostNode,
      hostAccountId: kFilesLocalAccountId,
      proxy: h.proxy,
      transport: FakePeerRangeTransport(fakeStatusStream(206)),
      isConnected: (_) => true,
    ).playable('/srv/films/Quiet Meridian (2027).mkv');
    expect(h.proxy.holders[target], hasLength(1));

    // One account withdrawn: the host still lends, so playback keeps it.
    h.client.list.value = [lentFlocal()];
    await _settle();
    expect(h.proxy.stops, isEmpty);

    h.client.list.value = const [];
    await _settle();
    expect(h.proxy.stops, [target]);
    expect(h.proxy.holders[target], isEmpty);
  });

  test('a peer source probes again when its host connects', () async {
    final backend = FakeBackend({},
        probeFailure: const BackendUnreachable('peer not connected'));
    h.backends[peerFilesSource(lentFlocal())] = backend;
    h.client.list.value = [lentFlocal()];
    final c = await container();
    final peerId = c.read(sourcesProvider).last.id;
    final peer = c.read(mediaSourceProvider(peerId))! as FilesMediaSource;
    await _settle();
    expect(peer.connection, SourceConnectionStatus.unreachable);

    backend.probeFailure = null;
    h.connected.add('some other node');
    await _settle();
    expect(peer.connection, SourceConnectionStatus.unreachable);

    // Node ids compare without regard to case, as the roster's do.
    h.connected.add(hostNode.toUpperCase());
    await _settle();
    expect(peer.connection, SourceConnectionStatus.local);
  });

  test('pull to refresh asks the host of each peer source among the ids',
      () async {
    h.client.list.value = [lentFlocal()];
    final c = await container();
    final ids = c.read(sourcesProvider).map((s) => s.id).toList();
    expect(ids, hasLength(2));

    // This device's own source asks nobody.
    await refreshPeerFilesSources(c.read, [ids.first]);
    expect(h.client.refreshed, isEmpty);

    await refreshPeerFilesSources(c.read, ids);
    expect(h.client.refreshed, [hostNode]);
  });

  test('revoked_host_removes_sources', () async {
    h.client.list.value = [lentFlocal()];
    final c = await container();
    final peerId = c.read(sourcesProvider).last.id;
    expect(c.read(mediaSourceProvider(peerId)), isNotNull);

    // The client drops a revoked host's accounts.
    h.client.list.value = const [];
    expect(c.read(sourcesProvider).map((s) => s.account.id),
        [kFilesLocalAccountId]);
    expect(c.read(mediaSourceProvider(peerId)), isNull);
  });

  test('no peer sources when the copies box is not open', () async {
    final c = ProviderContainer(overrides: [
      ...noHiveOverrides,
      sourceStoreProvider.overrideWith((ref) async => InMemorySourceStore()),
    ]);
    addTearDown(c.dispose);
    await c.read(sourceRecordsProvider.future);
    expect(c.read(sourcesProvider), isEmpty);
  });
}
