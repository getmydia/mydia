import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/p2p/p2p_range_stream.dart';
import 'package:player/core/p2p/peer_files_client.dart';
import 'package:player/core/p2p/peer_files_host.dart' show filesDedupeKey;
import 'package:player/core/p2p/peer_files_store.dart';
import 'package:player/core/p2p/peer_files_transport.dart';
import 'package:player/core/p2p/peer_files_wire.dart';
import 'package:player/core/p2p/peer_group_secret.dart';
import 'package:player/core/p2p/peer_sync_records.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/relay/relay_api_client.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/native/lib.dart';

import '../../test_utils/mock_auth_storage.dart';

const _self = 'viewer-node';
const _tv = 'tv-node';
const _desk = 'desk-node';
const _smbId = 's0123456789abcdef';
const _webdavId = 'w0123456789abcdef';

final _t = DateTime.fromMillisecondsSinceEpoch(1700000000000);

/// What one paired device lends, and how it misbehaves.
class _FakeHost {
  final accounts = <FlutterWireSharedAccount>[];
  final pages = <String, List<FlutterWireIndexPage>>{};
  bool offline = false;

  /// Answers an index page in place of [pages] when it returns non-null.
  FlutterPeerFilesResponse? Function(FlutterPeerFilesRequest_IndexPage)?
      pageOverride;

  void lend(String accountId, String name, int revision, List<String> files,
      {String kind = 'local', String? dedupeKey, int pageCount = 1}) {
    accounts.removeWhere((a) => a.accountId == accountId);
    accounts.add(FlutterWireSharedAccount(
      accountId: accountId,
      kind: kind,
      name: name,
      dedupeKey: dedupeKey,
      revision: BigInt.from(revision),
    ));
    final records = [
      for (final f in files)
        IndexedFile(
          key: fileKeyFor('r', f),
          rootId: 'r',
          path: f,
          size: 1,
          modified: _t,
          firstSeen: _t,
        ),
    ];
    pages[accountId] = [
      for (var p = 0; p < pageCount; p++)
        FlutterWireIndexPage(
          roots: p == 0
              ? encodeJsonRecords([
                  const LibraryRoot(
                    id: 'r',
                    path: '/media',
                    kind: FilesLibraryKind.movies,
                    title: 'Media',
                  ),
                ], (r) => r.toMap())
              : const [],
          files: encodeJsonRecords(
            [
              for (var i = 0; i < records.length; i++)
                if (i % pageCount == p) records[i],
            ],
            (f) => f.toMap(),
          ),
          groups: const [],
          movies: const [],
          shows: const [],
        ),
    ];
  }

  void drop(String accountId) {
    accounts.removeWhere((a) => a.accountId == accountId);
    pages.remove(accountId);
  }
}

class _FakeFilesTransport implements PeerFilesTransport {
  _FakeFilesTransport(this.expectedProof);

  final String expectedProof;
  final hosts = <String, _FakeHost>{};
  final manifestCalls = <String>[];
  final pageCalls = <String>[];

  int manifestsFrom(String node) =>
      manifestCalls.where((n) => n == node).length;

  @override
  Future<FlutterPeerFilesResponse> sendPeerFiles(
      String peer, FlutterPeerFilesRequest request) async {
    final host = hosts[peer];
    if (host == null || host.offline) throw Exception('$peer unreachable');
    switch (request) {
      case FlutterPeerFilesRequest_Manifest(:final authProof):
        manifestCalls.add(peer);
        if (authProof != expectedProof) {
          return const FlutterPeerFilesResponse.notAuthorized();
        }
        return FlutterPeerFilesResponse.manifest(
            accounts: List.of(host.accounts));
      case FlutterPeerFilesRequest_IndexPage(
          :final accountId,
          :final revision,
          :final cursor,
        ):
        pageCalls.add('$peer/$accountId');
        if (host.pageOverride?.call(request) case final r?) return r;
        final current =
            host.accounts.where((a) => a.accountId == accountId).firstOrNull;
        if (current == null || current.revision != revision) {
          return const FlutterPeerFilesResponse.staleRevision();
        }
        final pages = host.pages[accountId]!;
        final at = cursor == null ? 0 : int.parse(cursor);
        return FlutterPeerFilesResponse.indexPage(
          page: pages[at],
          nextCursor: at + 1 < pages.length ? '${at + 1}' : null,
        );
    }
  }

  @override
  Stream<FlutterInboundPeerFilesRequest> get onPeerFilesRequest =>
      const Stream.empty();
  @override
  Stream<FlutterPeerFileGrantRequest> get onPeerFileGrantRequest =>
      const Stream.empty();
  @override
  Future<void> respondToPeerFiles(
          String requestId, FlutterPeerFilesResponse response) =>
      throw UnimplementedError();
  @override
  Future<void> respondPeerFileGrant(
          String requestId, FlutterPeerFileGrant? grant) =>
      throw UnimplementedError();
  @override
  Future<void> setPeerFilesMembers(List<String> nodeIds) =>
      throw UnimplementedError();
  @override
  Future<void> invalidatePeerFileGrants(String accountId) =>
      throw UnimplementedError();
  @override
  Future<P2pRangeStream> openRangeStream({
    required String peer,
    required String sessionId,
    required String path,
    int? rangeStart,
    int? rangeEnd,
    String? authToken,
  }) =>
      throw UnimplementedError();
}

/// PeerSync transport that never reaches anyone.
class _QuietSyncTransport implements PeerSyncTransport {
  final _inbound = StreamController<FlutterInboundPeerSyncRequest>.broadcast();
  final _connected = StreamController<String>.broadcast();

  @override
  String? get nodeId => _self;
  @override
  String? get nodeAddr => null;
  @override
  Stream<FlutterInboundPeerSyncRequest> get onPeerSyncRequest =>
      _inbound.stream;
  @override
  Stream<String> get onPeerConnected => _connected.stream;
  @override
  Future<void> initialize() async {}
  @override
  Future<String?> getNodeAddr() async => null;
  @override
  Future<void> dial(String endpointAddrJson) async {}
  @override
  Future<void> addAddressHint(String endpointAddrJson) async {}
  @override
  Future<FlutterPeerSyncResponse> sendPeerSync(
          String peer, FlutterPeerSyncRequest req) =>
      Future.error(Exception('unreachable'));
  @override
  Future<void> respondToPeerSync(
      String requestId, FlutterPeerSyncResponse res) async {}
  @override
  bool isConnectedToPeer(String peer) => false;

  void dispose() {
    _inbound.close();
    _connected.close();
  }
}

SourceAccountRecord _filesRecord(String id, String name,
    {List<ServerConnection> connections = const []}) {
  return SourceAccountRecord(
    account: ProviderAccount(
      id: id,
      kind: SourceKind.files,
      displayName: name,
      storageNamespace: 'source/$id',
      activeProfileId: kOwnerProfileId,
    ),
    profiles: [
      SourceProfile(
          id: kOwnerProfileId, accountId: id, name: 'Owner', isOwner: true),
    ],
    servers: [
      SourceServer(
        id: id == kFilesLocalAccountId ? kFilesLocalServerId : id,
        accountId: id,
        profileId: kOwnerProfileId,
        name: name,
        connections: connections,
      ),
    ],
    addedAtMs: 0,
  );
}

void main() {
  late Directory dir;
  late Box<Map<dynamic, dynamic>> box;
  late PeerFilesStore store;
  late _FakeFilesTransport transport;
  late _QuietSyncTransport syncTransport;
  late InMemoryPeerSyncStore syncStore;
  late PeerSyncService sync;
  late List<SourceAccountRecord> local;
  late StreamController<String> connected;
  late PeerFilesClient client;
  var n = 0;

  _FakeHost tv() => transport.hosts[_tv]!;
  _FakeHost desk() => transport.hosts[_desk]!;

  PeerFilesClient newClient() => PeerFilesClient(
        transport: transport,
        sync: sync,
        store: store,
        localAccounts: () => local,
        peerConnected: connected.stream,
      );

  List<String> shown() => [
        for (final a in client.accounts.value)
          '${a.deviceName} · ${a.wire.name}',
      ];

  List<String> indexed(String nodeId, String accountId) => [
        for (final f in store
            .index(peerFilesAccountId(nodeId, accountId))
            .files()
            .values)
          f.path,
      ]..sort();

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('peer_files_client_test');
    Hive.init(dir.path);
    box = await Hive.openBox<Map<dynamic, dynamic>>('pfc_${n++}');
    store = PeerFilesStore(box);

    syncTransport = _QuietSyncTransport();
    syncStore = InMemoryPeerSyncStore();
    final auth = MockAuthStorage();
    final secret = PeerGroupSecret.generate();
    await auth.write(PeerGroupSecret.storageKey, secret.toBase64Url());
    for (final (id, name) in [
      (_self, 'Viewer'),
      (_tv, 'Living Room TV'),
      (_desk, 'Desk'),
    ]) {
      await syncStore.putMember(PeerMember(
        nodeId: id,
        deviceName: name,
        platform: 'linux',
        updatedAt: 1,
      ));
    }
    sync = PeerSyncService(
      store: syncStore,
      authStorage: auth,
      transport: syncTransport,
      relayClient: RelayApiClient(),
      deviceName: 'Viewer',
      platform: 'linux',
      resolveDeviceName: () async => 'Viewer',
    );
    await sync.start();

    transport = _FakeFilesTransport(secret.authProof(_self));
    transport.hosts[_tv] = _FakeHost()
      ..lend(kFilesLocalAccountId, 'Films', 1, ['Paper Moon Harbor.mkv']);
    transport.hosts[_desk] = _FakeHost()
      ..lend(_smbId, 'NAS', 3, ['Glass Orchard.mkv'],
          kind: 'smb', dedupeKey: 'smb://nas.local/media');
    local = [_filesRecord(kFilesLocalAccountId, 'This device')];
    connected = StreamController<String>.broadcast();
    client = newClient();
  });

  tearDown(() async {
    client.dispose();
    sync.dispose();
    syncTransport.dispose();
    await connected.close();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  test('builds_accounts_from_manifest', () async {
    await client.start();

    expect(shown(), ['Desk · NAS', 'Living Room TV · Films']);
    final films = client.accounts.value.singleWhere((a) => a.nodeId == _tv);
    expect(films.wire.accountId, kFilesLocalAccountId);
    expect(films.localAccountId, peerFilesAccountId(_tv, kFilesLocalAccountId));
    expect(indexed(_tv, kFilesLocalAccountId), ['Paper Moon Harbor.mkv']);
    expect(indexed(_desk, _smbId), ['Glass Orchard.mkv']);
    expect(store.revision(films.localAccountId), 1);
  });

  test('skips_peer_smb_matching_local_smb', () async {
    final nas = _filesRecord(_smbId, 'My NAS', connections: [
      ServerConnection(uri: Uri.parse('smb://192.168.1.20/Media')),
      ServerConnection(uri: Uri.parse('smb://NAS.local/Media')),
    ]);
    final dav = _filesRecord(_webdavId, 'Cloud', connections: [
      ServerConnection(uri: Uri.parse('https://dav.example.test/files/')),
    ]);
    local = [...local, nas, dav];
    desk()
      ..drop(_smbId)
      ..lend('s1111111111111111', 'NAS', 1, ['Glass Orchard.mkv'],
          kind: 'smb', dedupeKey: filesDedupeKey(nas))
      ..lend('w1111111111111111', 'Cloud', 1, ['Fern Clock.mkv'],
          kind: 'webdav', dedupeKey: filesDedupeKey(dav))
      ..lend('s2222222222222222', 'Attic', 1, ['Tin Comet.mkv'],
          kind: 'smb', dedupeKey: 'smb://attic.local/share');

    await client.start();

    expect(shown(), ['Desk · Attic', 'Living Room TV · Films']);
    expect(transport.pageCalls.where((c) => c.contains('1111')), isEmpty);

    // Once the local share is gone, the peer's copy appears.
    local = [_filesRecord(kFilesLocalAccountId, 'This device')];
    await client.refresh();
    expect(shown(), [
      'Desk · Attic',
      'Desk · Cloud',
      'Desk · NAS',
      'Living Room TV · Films',
    ]);
  });

  test('never_skips_flocal', () async {
    final nas = _filesRecord(_smbId, 'My NAS', connections: [
      ServerConnection(uri: Uri.parse('smb://NAS.local/Media')),
    ]);
    local = [...local, nas];
    // Even a local-folders entry carrying a key that matches a local share
    // names folders on the host, never that share.
    tv().lend(kFilesLocalAccountId, 'Films', 1, ['Paper Moon Harbor.mkv'],
        dedupeKey: filesDedupeKey(nas));

    await client.start();

    expect(shown(), contains('Living Room TV · Films'));
    expect(indexed(_tv, kFilesLocalAccountId), ['Paper Moon Harbor.mkv']);
  });

  test('unchanged_revision_not_refetched', () async {
    await client.start();
    expect(transport.pageCalls, hasLength(2));

    await client.refresh();
    await client.refresh(nodeId: _tv);
    expect(transport.manifestsFrom(_tv), 3);
    expect(transport.pageCalls, hasLength(2));

    tv().lend(kFilesLocalAccountId, 'Films', 2,
        ['Paper Moon Harbor.mkv', 'Cedar Signal.mkv']);
    await client.refresh();
    expect(transport.pageCalls, hasLength(3));
    expect(indexed(_tv, kFilesLocalAccountId),
        ['Cedar Signal.mkv', 'Paper Moon Harbor.mkv']);
    expect(store.revision(peerFilesAccountId(_tv, kFilesLocalAccountId)), 2);
  });

  test('failed_page_keeps_old_index', () async {
    await client.start();
    final id = peerFilesAccountId(_tv, kFilesLocalAccountId);

    tv()
      ..lend(kFilesLocalAccountId, 'Films', 2,
          ['Cedar Signal.mkv', 'Wren Lighthouse.mkv', 'Velvet Ferry.mkv'],
          pageCount: 3)
      ..pageOverride = (r) => r.cursor == '2' ? throw Exception('cut') : null;
    await client.refresh();
    expect(store.revision(id), 1);
    expect(indexed(_tv, kFilesLocalAccountId), ['Paper Moon Harbor.mkv']);
    expect(shown(), contains('Living Room TV · Films'));

    // A refusal part way through is a failure too.
    tv().pageOverride = (r) =>
        r.cursor == '1' ? const FlutterPeerFilesResponse.notAuthorized() : null;
    await client.refresh();
    expect(store.revision(id), 1);
    expect(indexed(_tv, kFilesLocalAccountId), ['Paper Moon Harbor.mkv']);

    tv().pageOverride = null;
    await client.refresh();
    expect(store.revision(id), 2);
    expect(indexed(_tv, kFilesLocalAccountId),
        ['Cedar Signal.mkv', 'Velvet Ferry.mkv', 'Wren Lighthouse.mkv']);
  });

  test('stale_revision_restarts_at_most_twice', () async {
    await client.start();
    final id = peerFilesAccountId(_tv, kFilesLocalAccountId);

    // A host that rescans faster than this device can read.
    tv()
      ..lend(kFilesLocalAccountId, 'Films', 2, ['Cedar Signal.mkv'])
      ..pageOverride = (_) => const FlutterPeerFilesResponse.staleRevision();
    final before = transport.manifestsFrom(_tv);
    await client.refresh(nodeId: _tv);
    expect(transport.manifestsFrom(_tv) - before, 3);
    expect(store.revision(id), 1);
    expect(indexed(_tv, kFilesLocalAccountId), ['Paper Moon Harbor.mkv']);

    // One bump mid-fetch: the restart reads the new revision and lands it.
    var stale = 1;
    tv().pageOverride = (r) {
      if (stale-- <= 0) return null;
      tv().lend(kFilesLocalAccountId, 'Films', 3, ['Velvet Ferry.mkv']);
      return const FlutterPeerFilesResponse.staleRevision();
    };
    await client.refresh(nodeId: _tv);
    expect(store.revision(id), 3);
    expect(indexed(_tv, kFilesLocalAccountId), ['Velvet Ferry.mkv']);
  });

  test('removed_on_manifest_drop_revocation_and_leave', () async {
    tv().lend('w2222222222222222', 'Concerts', 1, ['Brass Tide.mkv'],
        kind: 'webdav', dedupeKey: 'https://dav.tv.test/');
    await client.start();
    expect(shown(), [
      'Desk · NAS',
      'Living Room TV · Concerts',
      'Living Room TV · Films',
    ]);
    final concerts = peerFilesAccountId(_tv, 'w2222222222222222');
    final films = peerFilesAccountId(_tv, kFilesLocalAccountId);
    final nas = peerFilesAccountId(_desk, _smbId);

    tv().drop('w2222222222222222');
    await client.refresh();
    expect(shown(), ['Desk · NAS', 'Living Room TV · Films']);
    expect(store.revision(concerts), isNull);
    expect(store.index(concerts).files(), isEmpty);

    await sync.revokePeer(_tv);
    await client.refresh();
    expect(shown(), ['Desk · NAS']);
    expect(store.revision(films), isNull);

    await sync.leaveGroup();
    await client.refresh();
    expect(client.accounts.value, isEmpty);
    expect(store.revision(nas), isNull);
    expect(store.storedAccounts(), isEmpty);
  });

  test('offline_member_keeps_accounts', () async {
    await client.start();
    tv().offline = true;
    await client.refresh();
    expect(shown(), ['Desk · NAS', 'Living Room TV · Films']);
    expect(indexed(_tv, kFilesLocalAccountId), ['Paper Moon Harbor.mkv']);

    // And across a restart with the host still away.
    client.dispose();
    client = newClient();
    await client.start();
    expect(shown(), ['Desk · NAS', 'Living Room TV · Films']);
    expect(indexed(_tv, kFilesLocalAccountId), ['Paper Moon Harbor.mkv']);
  });

  test('local_account_id_is_namespaced', () {
    final fromTv = peerFilesAccountId(_tv, kFilesLocalAccountId);
    final fromDesk = peerFilesAccountId(_desk, kFilesLocalAccountId);
    expect(fromTv, isNot(fromDesk));
    expect(fromTv, isNot(kFilesLocalAccountId));
    expect(fromDesk, isNot(kFilesLocalAccountId));
    expect(fromTv, matches(RegExp(r'^p[0-9a-f]{12}_flocal$')));
    // SHA-256("tv-node"), first 12 hex characters.
    expect(fromTv, 'p833694a5e777_flocal');
  });

  test('refreshes_on_state_change_and_peer_connected', () async {
    await client.start();
    final before = transport.manifestsFrom(_tv);

    connected.add(_tv);
    await pumpEventQueue();
    await client.refresh(nodeId: _desk);
    expect(transport.manifestsFrom(_tv), before + 1);

    // A device that is not a member is not asked.
    connected.add('stranger-node');
    await pumpEventQueue();
    expect(transport.manifestCalls, isNot(contains('stranger-node')));

    tv().lend(kFilesLocalAccountId, 'Films', 5, ['Cedar Signal.mkv']);
    await sync.revokePeer(_desk);
    await pumpEventQueue();
    await client.refresh(nodeId: _desk);
    expect(indexed(_tv, kFilesLocalAccountId), ['Cedar Signal.mkv']);
    expect(shown(), ['Living Room TV · Films']);
  });
}
