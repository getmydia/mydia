import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:hive_ce/hive.dart';
import 'package:player/core/p2p/media_proxy_factory.dart';
import 'package:player/core/p2p/peer_files_client.dart';
import 'package:player/core/p2p/peer_files_store.dart';
import 'package:player/core/p2p/peer_files_wire.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_providers.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/files/peer_files_sources.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/native/lib.dart';

import '../../../test_utils/no_downloads.dart';
import '../../p2p/fake_peer_files.dart';
import 'fake_backend.dart';
import 'fake_media_names.dart';
import 'files_fixture.dart';

const hostNode =
    'aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44';
final peerLocalId = peerFilesAccountId(hostNode, kFilesLocalAccountId);

/// A client whose lent accounts the test sets.
class FakePeerFilesClient implements PeerFilesClient {
  final list = ValueNotifier<List<PeerSharedAccount>>(const []);

  @override
  ValueListenable<List<PeerSharedAccount>> get accounts => list;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Takes the local mutation nudges a watched toggle sends, and nothing else.
class QuietPeerSync implements PeerSyncService {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

PeerSharedAccount lentFlocal({
  int revision = 1,
  String name = 'Folders',
  String accountId = kFilesLocalAccountId,
}) =>
    PeerSharedAccount(
      nodeId: hostNode,
      deviceName: 'Den Desktop',
      wire: FlutterWireSharedAccount(
        accountId: accountId,
        kind: 'local',
        name: name,
        revision: BigInt.from(revision),
      ),
    );

/// The host's own `flocal` index: one invented film and a loose file whose
/// name could not be read, under a root of its own.
Future<FileLibraryIndex> hostIndex(Box<Map<dynamic, dynamic>> box) async {
  final index = FileLibraryIndex(box, accountId: kFilesLocalAccountId);
  await index.putRoot(const LibraryRoot(
    id: 'rhost',
    path: '/srv/films',
    kind: FilesLibraryKind.mixed,
    title: 'Host films',
  ));
  final parsed = FakeMediaNames()
      .parseBatch(
          '/srv/films', ['Quiet Meridian (2027).mkv'], FilesLibraryKind.mixed)
      .single;
  await index.putFiles([
    IndexedFile(
      key: fileKeyFor('rhost', parsed.path),
      rootId: 'rhost',
      path: parsed.path,
      size: 1000,
      modified: filesT0,
      firstSeen: filesT0,
      parsed: parsed,
    ),
    IndexedFile(
      key: fileKeyFor('rhost', 'clips/beach day.mkv'),
      rootId: 'rhost',
      path: 'clips/beach day.mkv',
      size: 10,
      modified: filesT0,
      firstSeen: filesT0,
    ),
  ]);
  await index.putGroup(GroupMatch(
    groupKey: parsed.groupKey,
    isShow: false,
    tmdbId: 301,
    matchedAt: filesT0,
  ));
  await index.putMovie(const MatchedMovie(
    tmdbId: 301,
    title: 'Quiet Meridian',
    year: 2027,
  ));
  return index;
}

/// Everything a peer source needs, over [f]'s boxes: a copy of the host's
/// index in a real [PeerFilesStore], and a client that lends it once the
/// test says so.
class PeerHarness {
  PeerHarness(this.f);

  final FilesFixture f;
  final client = FakePeerFilesClient();

  /// The backend each source was built with; none of them is real.
  final backends = <Source, FakeBackend>{};
  final syncStore = InMemoryPeerSyncStore();
  final proxy = FakePeerProxy();

  /// Node ids of paired players as they connect. Never closed: it lives
  /// as long as the test's container.
  // ignore: close_sinks
  final connected = StreamController<String>.broadcast();
  late PeerFilesStore store;
  late FileLibraryIndex host;

  Future<void> seed() async {
    store = PeerFilesStore(
        await Hive.openBox<Map<dynamic, dynamic>>('peer_files_test'));
    host = await hostIndex(
        await Hive.openBox<Map<dynamic, dynamic>>('host_index_test'));
    await store.replace(peerLocalId, 1, pageIndex(host));
  }

  List<Override> overrides(SourceStore sources) => [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => sources),
        filesIndexBoxProvider.overrideWithValue(f.box),
        filesProgressStoreProvider.overrideWithValue(f.progress),
        mediaNamesProvider.overrideWithValue(FakeMediaNames()),
        relayTmdbProvider.overrideWithValue(FakeFilesRelay()),
        filesBackendBuilderProvider.overrideWithValue((ref, source) =>
            backends.putIfAbsent(source, () => FakeBackend({}))),
        filesClockProvider.overrideWithValue(() => DateTime.utc(2030)),
        peerFilesStoreProvider.overrideWithValue(store),
        peerFilesClientProvider.overrideWithValue(client),
        peerSyncStoreProvider.overrideWithValue(syncStore),
        peerSyncServiceProvider.overrideWithValue(QuietPeerSync()),
        peerConnectedProvider.overrideWithValue(connected.stream),
        mediaProxyProvider.overrideWithValue(proxy),
      ];

  /// A container that also holds this device's own `flocal` account.
  Future<ProviderContainer> container() async {
    final sources = InMemorySourceStore();
    await sources.putAccount(filesLocalRecord);
    final c = ProviderContainer(overrides: overrides(sources));
    await c.read(sourceRecordsProvider.future);
    return c;
  }
}
