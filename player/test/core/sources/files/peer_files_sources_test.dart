import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_files_wire.dart';
import 'package:player/core/p2p/peer_sync_records.dart';
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

  test('a new copy of the host index rebuilds the source on it', () async {
    h.client.list.value = [lentFlocal()];
    final c = await container();
    final peerId = c.read(sourcesProvider).last.id;
    final first = c.read(mediaSourceProvider(peerId))! as FilesMediaSource;
    expect(first.index.files(), hasLength(2));

    await h.host.removeFiles([fileKeyFor('rhost', 'clips/beach day.mkv')]);
    await h.store.replace(peerLocalId, 2, pageIndex(h.host));
    h.client.list.value = [lentFlocal(revision: 2)];

    final second = c.read(mediaSourceProvider(peerId))! as FilesMediaSource;
    expect(identical(first, second), isFalse);
    expect(second.index.files(), hasLength(1));
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
