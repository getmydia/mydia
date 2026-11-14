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

  /// Answers every manifest with this instead of the accounts it lends.
  FlutterPeerFilesResponse? manifestOverride;

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
        if (host.manifestOverride case final r?) return r;
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
          String requestId, FlutterPeerFileGrantAnswer answer) =>
      throw UnimplementedError();
  @override
  Future<void> dial(String endpointAddrJson) => throw UnimplementedError();
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
  late MockAuthStorage auth;
  late PeerGroupSecret secret;
  late List<SourceAccountRecord>? local;
  late Future<void> Function()? localReady;
  late StreamController<void> localChanges;
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
        localAccountsReady: localReady,
        localAccountsChanged: localChanges.stream,
        peerConnected: connected.stream,
      );

  PeerSyncService newSync(MockAuthStorage storage) => PeerSyncService(
        store: syncStore,
        authStorage: storage,
        transport: syncTransport,
        relayClient: RelayApiClient(),
        deviceName: 'Viewer',
        platform: 'linux',
        resolveDeviceName: () async => 'Viewer',
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
    auth = MockAuthStorage();
    secret = PeerGroupSecret.generate();
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
    sync = newSync(auth);
    await sync.start();

    transport = _FakeFilesTransport(secret.authProof(_self));
    transport.hosts[_tv] = _FakeHost()
      ..lend(kFilesLocalAccountId, 'Films', 1, ['Paper Moon Harbor.mkv']);
    transport.hosts[_desk] = _FakeHost()
      ..lend(_smbId, 'NAS', 3, ['Glass Orchard.mkv'],
          kind: 'smb', dedupeKey: 'smb://nas.local/media');
    local = [_filesRecord(kFilesLocalAccountId, 'This device')];
    localReady = null;
    localChanges = StreamController<void>.broadcast();
    connected = StreamController<String>.broadcast();
    client = newClient();
  });

  tearDown(() async {
    client.dispose();
    sync.dispose();
    syncTransport.dispose();
    await connected.close();
    await localChanges.close();
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
    local = [...?local, nas, dav];
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
    local = [...?local, nas];
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

  test('sync_start_failure_keeps_indexes', () async {
    await client.start();
    client.dispose();
    sync.dispose();

    // The group secret cannot be read this launch: sync knows no members.
    sync = newSync(_UnreadableAuthStorage());
    await expectLater(sync.start(), throwsA(anything));
    expect(sync.activeMemberIds(), isEmpty);

    client = newClient();
    await client.start();
    await client.refresh();
    expect(store.revision(peerFilesAccountId(_tv, kFilesLocalAccountId)), 1);
    expect(store.revision(peerFilesAccountId(_desk, _smbId)), 3);
    expect(store.storedAccounts(), hasLength(2));
    expect(indexed(_tv, kFilesLocalAccountId), ['Paper Moon Harbor.mkv']);
  });

  test('refresh_during_a_failed_leave_keeps_indexes', () async {
    await client.start();
    auth.failDeleteKeys.add(PeerGroupSecret.storageKey);
    // Out of reach, so nothing lost here could be fetched back.
    tv().offline = true;
    desk().offline = true;

    final leaving = sync.leaveGroup();
    // Mid-leave the member list reads empty; that proves nothing.
    final refreshed = client.refresh();
    await expectLater(leaving, throwsA(anything));
    await refreshed;
    await client.refresh();

    expect(shown(), ['Desk · NAS', 'Living Room TV · Films']);
    expect(store.revision(peerFilesAccountId(_tv, kFilesLocalAccountId)), 1);
    expect(store.storedAccounts(), hasLength(2));
  });

  test('completed_leave_removes_everything_without_a_refresh', () async {
    await client.start();
    await sync.leaveGroup();
    // The deletes are box writes, not microtasks: under a loaded suite a
    // fixed pump can finish before they land, so wait for them (bounded).
    for (var i = 0; i < 100 && store.storedAccounts().isNotEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(client.accounts.value, isEmpty);
    expect(store.storedAccounts(), isEmpty);
    expect(store.revision(peerFilesAccountId(_desk, _smbId)), isNull);
  });

  test('a host answering Revoked tears down its copies, NotAuthorized does not',
      () async {
    await client.start();
    final films = peerFilesAccountId(_tv, kFilesLocalAccountId);

    // Refusing proves nothing: the host's secret may not have loaded.
    tv().manifestOverride = const FlutterPeerFilesResponse.notAuthorized();
    await client.refresh();
    expect(shown(), ['Desk · NAS', 'Living Room TV · Films']);

    // This device's own roster still holds the TV, active: only the host
    // knows it revoked this device.
    tv().manifestOverride = const FlutterPeerFilesResponse.revoked();
    await client.refresh();
    expect(shown(), ['Desk · NAS']);
    expect(store.revision(films), isNull);
    expect(store.storedAccounts().map((a) => a.nodeId), [_desk]);
    expect(sync.member(_tv)!.revoked, isFalse);
  });

  test('an index page answered Revoked tears down that host', () async {
    tv().lend('w2222222222222222', 'Concerts', 1, ['Brass Tide.mkv'],
        kind: 'webdav', dedupeKey: 'https://dav.tv.test/');
    await client.start();
    expect(shown(), hasLength(3));

    tv().lend(kFilesLocalAccountId, 'Films', 2, ['Cedar Signal.mkv']);
    tv().pageOverride = (_) => const FlutterPeerFilesResponse.revoked();
    await client.refresh(nodeId: _tv);
    expect(shown(), ['Desk · NAS']);
    expect(store.storedAccounts().map((a) => a.nodeId), [_desk]);
  });

  test('a failing delete of a revoked copy does not stop start', () async {
    await client.start();
    client.dispose();
    await syncStore.putMember(const PeerMember(
      nodeId: _tv,
      deviceName: 'Living Room TV',
      platform: 'linux',
      updatedAt: 99,
      revoked: true,
    ));
    store = _UnremovableStore(box);
    client = newClient();
    await client.start();
    // Started, refreshed and published regardless.
    expect(shown(), ['Desk · NAS']);
    expect(transport.manifestsFrom(_desk), 2);
  });

  test('host_revoked_while_closed_never_shows', () async {
    await client.start();
    client.dispose();
    await syncStore.putMember(const PeerMember(
      nodeId: _tv,
      deviceName: 'Living Room TV',
      platform: 'linux',
      updatedAt: 99,
      revoked: true,
    ));
    tv().offline = true;

    client = newClient();
    final seen = <List<String>>[];
    client.accounts.addListener(() => seen.add(shown()));
    await client.start();

    expect(seen.expand((s) => s), isNot(contains('Living Room TV · Films')));
    expect(shown(), ['Desk · NAS']);
    expect(
        store.revision(peerFilesAccountId(_tv, kFilesLocalAccountId)), isNull);
  });

  test('waits_for_local_accounts_before_deciding_dedupe', () async {
    final nas = _filesRecord(_smbId, 'My NAS', connections: [
      ServerConnection(uri: Uri.parse('smb://NAS.local/Media')),
    ]);
    desk().lend(_smbId, 'NAS', 3, ['Glass Orchard.mkv'],
        kind: 'smb', dedupeKey: filesDedupeKey(nas));
    local = null;
    final ready = Completer<void>();
    localReady = () => ready.future;
    client.dispose();
    client = newClient();

    final starting = client.start();
    await pumpEventQueue();
    expect(transport.manifestCalls, isEmpty);

    local = [_filesRecord(kFilesLocalAccountId, 'This device'), nas];
    ready.complete();
    await starting;

    expect(shown(), ['Living Room TV · Films']);
    expect(transport.pageCalls, isNot(contains('$_desk/$_smbId')));
    expect(store.revision(peerFilesAccountId(_desk, _smbId)), isNull);
  });

  test('unknown_local_accounts_leave_shares_undecided', () async {
    // The stored sources failed to load: deciding with an empty set would
    // fetch a copy of a share this device may have itself.
    local = null;
    localReady = () => Future.error(Exception('records unreadable'));
    client.dispose();
    client = newClient();

    await client.start();
    expect(shown(), ['Living Room TV · Films']);
    expect(transport.pageCalls, isNot(contains('$_desk/$_smbId')));

    // Once they load, without a match, the share is fetched and shown.
    local = [_filesRecord(kFilesLocalAccountId, 'This device')];
    localChanges.add(null);
    await pumpEventQueue();
    await client.refresh(nodeId: 'nobody');
    expect(shown(), ['Desk · NAS', 'Living Room TV · Films']);
  });

  test('local_account_change_refreshes_dedupe', () async {
    final nas = _filesRecord(_smbId, 'My NAS', connections: [
      ServerConnection(uri: Uri.parse('smb://NAS.local/Media')),
    ]);
    desk().lend(_smbId, 'NAS', 3, ['Glass Orchard.mkv'],
        kind: 'smb', dedupeKey: filesDedupeKey(nas));
    await client.start();
    expect(shown(), ['Desk · NAS', 'Living Room TV · Films']);
    final manifests = transport.manifestCalls.length;

    // A change that moves no dedupe key costs no refresh.
    local = [_filesRecord(kFilesLocalAccountId, 'Renamed device')];
    localChanges.add(null);
    await pumpEventQueue();
    expect(transport.manifestCalls.length, manifests);

    local = [...?local, nas];
    localChanges.add(null);
    await pumpEventQueue();
    await client.refresh(nodeId: 'nobody');
    expect(shown(), ['Living Room TV · Films']);
    expect(store.revision(peerFilesAccountId(_desk, _smbId)), isNull);
  });
}

class _UnreadableAuthStorage extends MockAuthStorage {
  @override
  Future<String?> read(String key) async => throw Exception('keyring locked');
}

/// A store whose box refuses deletes, as a corrupt Hive box can.
class _UnremovableStore extends PeerFilesStore {
  _UnremovableStore(super.box);

  @override
  Future<void> remove(String localAccountId) async =>
      throw HiveError('box is corrupt');
}
