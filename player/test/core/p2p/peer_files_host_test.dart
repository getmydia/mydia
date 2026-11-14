import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/core/p2p/p2p_range_stream.dart';
import 'package:player/core/p2p/peer_files_host.dart';
import 'package:player/core/p2p/peer_files_transport.dart';
import 'package:player/core/p2p/peer_files_wire.dart';
import 'package:player/core/p2p/peer_group_secret.dart';
import 'package:player/core/p2p/peer_sync_records.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/relay/relay_api_client.dart';
import 'package:player/core/sources/files/backend/file_system_backend.dart';
import 'package:player/core/sources/files/files_account.dart';
import 'package:player/core/sources/files/files_queries.dart'
    show filesBackendPath;
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/native/lib.dart';

import '../../test_utils/mock_auth_storage.dart';

const _hostNode = 'host-node';
const _viewerNode = 'viewer-node';
const _smbAccount = 's0123456789abcdef';

class _FakeFilesTransport implements PeerFilesTransport {
  // Both closed in tearDown.
  // ignore: close_sinks
  final requests = StreamController<FlutterInboundPeerFilesRequest>();
  // ignore: close_sinks
  final grants = StreamController<FlutterPeerFileGrantRequest>();
  final responses = <String, FlutterPeerFilesResponse>{};
  final grantAnswers = <String, FlutterPeerFileGrantAnswer>{};
  final members = <List<String>>[];
  final invalidated = <String>[];

  @override
  Stream<FlutterInboundPeerFilesRequest> get onPeerFilesRequest =>
      requests.stream;

  @override
  Stream<FlutterPeerFileGrantRequest> get onPeerFileGrantRequest =>
      grants.stream;

  @override
  Future<void> respondToPeerFiles(
    String requestId,
    FlutterPeerFilesResponse response,
  ) async {
    responses[requestId] = response;
  }

  @override
  Future<void> respondPeerFileGrant(
    String requestId,
    FlutterPeerFileGrantAnswer answer,
  ) async {
    grantAnswers[requestId] = answer;
  }

  @override
  Future<void> dial(String endpointAddrJson) => throw UnimplementedError();

  @override
  Future<void> setPeerFilesMembers(List<String> nodeIds) async {
    members.add(nodeIds);
    if (membersGate case final gate?) await gate.future;
    if (failMembers) throw Exception('host gone');
  }

  bool failMembers = false;

  /// When set, a push does not land until it completes.
  Completer<void>? membersGate;

  @override
  Future<void> invalidatePeerFileGrants(String accountId) async {
    invalidated.add(accountId);
  }

  @override
  Future<FlutterPeerFilesResponse> sendPeerFiles(
          String peer, FlutterPeerFilesRequest request) =>
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

/// PeerSync transport for a host that never reaches anyone: only the parts
/// [PeerSyncService.start], [revokePeer] and [leaveGroup] touch.
class _QuietSyncTransport implements PeerSyncTransport {
  final _inbound = StreamController<FlutterInboundPeerSyncRequest>.broadcast();
  final _connected = StreamController<String>.broadcast();

  @override
  String? get nodeId => _hostNode;
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

  /// Told of every sync request sent, by peer.
  void Function(String peer)? onSend;

  @override
  Future<FlutterPeerSyncResponse> sendPeerSync(
      String peer, FlutterPeerSyncRequest req) {
    onSend?.call(peer);
    return Future.error(Exception('unreachable'));
  }

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

class _RecordingBackend implements FileSystemBackend {
  final played = <String>[];
  BackendFailure? failure;

  @override
  Future<PlayableFile> playable(String path) async {
    played.add(path);
    if (failure case final f?) throw f;
    return PlayableFile(
      url: 'http://127.0.0.1:9/f?p=${Uri.encodeComponent(path)}',
      headers: const {'Authorization': 'Basic abc'},
    );
  }

  @override
  Future<List<FileEntry>> list(String dir) => throw UnimplementedError();
  @override
  Future<FileEntry?> stat(String path) => throw UnimplementedError();
  @override
  Future<void> probe() async {}
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

final _t = DateTime.fromMillisecondsSinceEpoch(1700000000000);

const _rootPaths = {
  'rmovies': '/media/films',
  'rshows': '/media/series',
  'rmix': '/media/mixed',
};

/// Three roots and 2,000 invented files, with groups, movies and shows.
Future<void> _seed(FileLibraryIndex index) async {
  for (final e in _rootPaths.entries) {
    await index.putRoot(LibraryRoot(
      id: e.key,
      path: e.value,
      kind: FilesLibraryKind.mixed,
      title: e.key,
    ));
  }
  final roots = _rootPaths.keys.toList();
  await index.putFiles([
    for (var i = 0; i < 2000; i++)
      IndexedFile(
        key: fileKeyFor(roots[i % 3], 'The Copper Lantern $i/Lantern $i.mkv'),
        rootId: roots[i % 3],
        path: 'The Copper Lantern $i/Lantern $i.mkv',
        size: 1000 + i,
        modified: _t,
        firstSeen: _t,
        parsed: ParsedName(
          path: 'The Copper Lantern $i/Lantern $i.mkv',
          isEpisode: false,
          title: 'The Copper Lantern $i',
          groupKey: 'thecopperlantern$i|',
        ),
        sidecars: [
          if (i == 7) 'The Copper Lantern 7/Lantern 7.en.srt',
        ],
      ),
  ]);
  for (var i = 0; i < 300; i++) {
    await index.putGroup(GroupMatch(
      groupKey: 'thecopperlantern$i|',
      isShow: false,
      tmdbId: 5000 + i,
      matchedAt: _t,
    ));
  }
  for (var i = 0; i < 50; i++) {
    await index.putMovie(MatchedMovie(
      tmdbId: 5000 + i,
      title: 'The Copper Lantern $i',
      overview: 'A lamp-lighter keeps harbor town number $i awake.',
    ));
  }
  await index.putShow(const MatchedShow(
    tmdbId: 9100,
    title: 'Saltmarsh Choir',
    seasons: {
      1: [MatchedEpisode(season: 1, episode: 1, title: 'Low Tide')],
    },
  ));
}

void main() {
  late Directory dir;
  late FileLibraryIndex localIndex;
  late FileLibraryIndex smbIndex;
  late _FakeFilesTransport transport;
  late _QuietSyncTransport syncTransport;
  late InMemoryPeerSyncStore store;
  late MockAuthStorage auth;
  late PeerGroupSecret secret;
  late PeerSyncService sync;
  late InMemoryPeerFilesRevisions revisions;
  late _RecordingBackend backend;
  late List<SourceAccountRecord> accounts;
  late PeerFilesHost host;
  var backendMissing = false;
  var n = 0;
  var requestCounter = 0;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('peer_files_host_test');
    Hive.init(dir.path);
    final box = await Hive.openBox<Map<dynamic, dynamic>>('idx_${n++}');
    localIndex = FileLibraryIndex(box, accountId: kFilesLocalAccountId);
    smbIndex = FileLibraryIndex(box, accountId: _smbAccount);
    await _seed(localIndex);
    await smbIndex.putRoot(const LibraryRoot(
      id: 'rshare',
      path: '/Media',
      kind: FilesLibraryKind.movies,
      title: 'Media',
    ));
    await smbIndex.putFiles([
      IndexedFile(
        key: fileKeyFor('rshare', 'Harbor Kites.mkv'),
        rootId: 'rshare',
        path: 'Harbor Kites.mkv',
        size: 10,
        modified: _t,
        firstSeen: _t,
      ),
    ]);

    transport = _FakeFilesTransport();
    syncTransport = _QuietSyncTransport();
    store = InMemoryPeerSyncStore();
    auth = MockAuthStorage();
    secret = PeerGroupSecret.generate();
    await auth.write(PeerGroupSecret.storageKey, secret.toBase64Url());
    for (final id in [_hostNode, _viewerNode]) {
      await store.putMember(PeerMember(
        nodeId: id,
        deviceName: id,
        platform: 'linux',
        updatedAt: 1,
      ));
    }
    sync = PeerSyncService(
      store: store,
      authStorage: auth,
      transport: syncTransport,
      relayClient: RelayApiClient(),
      deviceName: 'Host',
      platform: 'linux',
      resolveDeviceName: () async => 'Host',
    );
    await sync.start();

    // A clock at zero leaves each bump a plain increment.
    revisions = InMemoryPeerFilesRevisions(nowMs: () => 0);
    backend = _RecordingBackend();
    backendMissing = false;
    accounts = [
      _filesRecord(kFilesLocalAccountId, 'This device'),
      _filesRecord(_smbAccount, 'NAS', connections: [
        ServerConnection(uri: Uri.parse('smb://NAS.Local/Media')),
      ]),
      // A share another member lends this device: never offered onward.
      _filesRecord('p0123456789ab_flocal', 'Den'),
    ];
    host = PeerFilesHost(
      transport: transport,
      sync: sync,
      revisions: revisions,
      accounts: () => accounts,
      indexFor: (id) => id == _smbAccount ? smbIndex : localIndex,
      backendFor: (_) => backendMissing ? null : backend,
      pageBudget: 64 * 1024,
    );
    await host.start();
  });

  tearDown(() async {
    host.dispose();
    sync.dispose();
    syncTransport.dispose();
    await transport.requests.close();
    await transport.grants.close();
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Future<FlutterPeerFilesResponse> ask(
    FlutterPeerFilesRequest request, {
    String peer = _viewerNode,
  }) async {
    final id = 'req-${requestCounter++}';
    transport.requests.add(FlutterInboundPeerFilesRequest(
        peer: peer, requestId: id, request: request));
    await pumpEventQueue();
    return transport.responses[id]!;
  }

  const notShared = FlutterPeerFileGrantAnswer.notShared();
  const failed = FlutterPeerFileGrantAnswer.failed();

  Future<FlutterPeerFileGrantAnswer> grant(
      String accountId, String path) async {
    final id = 'grant-${requestCounter++}';
    transport.grants.add(FlutterPeerFileGrantRequest(
        requestId: id, accountId: accountId, path: path));
    await pumpEventQueue();
    expect(transport.grantAnswers.containsKey(id), isTrue);
    return transport.grantAnswers[id]!;
  }

  String proof([String node = _viewerNode]) => secret.authProof(node);

  FlutterPeerFilesRequest page(String account, int revision,
          [String? cursor]) =>
      FlutterPeerFilesRequest.indexPage(
        authProof: proof(),
        accountId: account,
        revision: BigInt.from(revision),
        cursor: cursor,
      );

  test('rejects_bad_proof', () async {
    final wrong = PeerGroupSecret.generate().authProof(_viewerNode);
    expect(await ask(FlutterPeerFilesRequest.manifest(authProof: wrong)),
        const FlutterPeerFilesResponse.notAuthorized());
    expect(
      await ask(FlutterPeerFilesRequest.indexPage(
        authProof: wrong,
        accountId: kFilesLocalAccountId,
        revision: BigInt.zero,
      )),
      const FlutterPeerFilesResponse.notAuthorized(),
    );
    // A proof made for another node does not carry over to this sender.
    expect(
      await ask(FlutterPeerFilesRequest.manifest(authProof: proof(_hostNode))),
      const FlutterPeerFilesResponse.notAuthorized(),
    );
  });

  test('a revoked member is told it was revoked', () async {
    await sync.revokePeer(_viewerNode);
    const revoked = FlutterPeerFilesResponse.revoked();
    expect(await ask(FlutterPeerFilesRequest.manifest(authProof: proof())),
        revoked);
    expect(await ask(page(kFilesLocalAccountId, 0)), revoked);
    // Whatever its proof: the roster is the evidence. The node id matches
    // without regard to case, as the roster does everywhere.
    final wrong = PeerGroupSecret.generate().authProof(_viewerNode);
    expect(
        await ask(FlutterPeerFilesRequest.manifest(authProof: wrong)), revoked);
    expect(
        await ask(FlutterPeerFilesRequest.manifest(authProof: proof()),
            peer: _viewerNode.toUpperCase()),
        revoked);

    // A node the roster has never held is refused, not revoked.
    expect(
      await ask(FlutterPeerFilesRequest.manifest(authProof: proof('stranger')),
          peer: 'stranger'),
      const FlutterPeerFilesResponse.notAuthorized(),
    );
  });

  test('manifest_lists_accounts_with_revision_and_dedupe_key', () async {
    await host.bumpRevision(_smbAccount);
    await host.bumpRevision(_smbAccount);
    final res = await ask(FlutterPeerFilesRequest.manifest(authProof: proof()));
    expect(res, isA<FlutterPeerFilesResponse_Manifest>());
    final accounts = (res as FlutterPeerFilesResponse_Manifest).accounts;
    expect(accounts, [
      FlutterWireSharedAccount(
        accountId: kFilesLocalAccountId,
        kind: 'local',
        name: 'This device',
        revision: BigInt.zero,
      ),
      FlutterWireSharedAccount(
        accountId: _smbAccount,
        kind: 'smb',
        name: 'NAS',
        dedupeKey: normalizeSmbUrl(Uri.parse('smb://NAS.Local/Media')),
        revision: BigInt.two,
      ),
    ]);
  });

  test('a hidden files account is never lent, locked or not', () async {
    const path = '/Media/Harbor Kites.mkv';
    expect(await grant(_smbAccount, path),
        isA<FlutterPeerFileGrantAnswer_Granted>());
    accounts = [
      for (final a in accounts)
        if (a.account.id == _smbAccount)
          a.copyWith(serverLocks: {_smbAccount: SourceLock.hidden})
        else
          a,
    ];
    final res = await ask(FlutterPeerFilesRequest.manifest(authProof: proof()));
    expect(
        (res as FlutterPeerFilesResponse_Manifest)
            .accounts
            .map((a) => a.accountId),
        [kFilesLocalAccountId]);
    expect(await ask(page(_smbAccount, 0)),
        const FlutterPeerFilesResponse.staleRevision());
    expect(await grant(_smbAccount, path), notShared);
    // Only hiding withdraws it. A PIN lock gates opening the source here,
    // where it still shows.
    accounts = [
      for (final a in accounts)
        if (a.account.id == _smbAccount)
          a.copyWith(serverLocks: {_smbAccount: SourceLock.locked})
        else
          a,
    ];
    expect(await grant(_smbAccount, path),
        isA<FlutterPeerFileGrantAnswer_Granted>());
    // Dedupe still sees it: a hidden share is this device's own.
    expect(
        sharedFilesAccounts([
          accounts[1].copyWith(serverLocks: {_smbAccount: SourceLock.hidden}),
        ]),
        hasLength(1));
  });

  test('a bump nudges the members with a throttled sync round', () async {
    // The viewer sits out its failure cooldown from the startup sync, which
    // this transport never completes; a member added since has none.
    await store.putMember(const PeerMember(
      nodeId: 'third-node',
      deviceName: 'third',
      platform: 'linux',
      updatedAt: 2,
    ));
    final rounds = <String>[];
    syncTransport.onSend = rounds.add;
    await host.bumpRevision(kFilesLocalAccountId);
    await host.bumpRevision(_smbAccount);
    expect(rounds, isEmpty, reason: 'throttled, not sent at once');
    await Future<void>.delayed(const Duration(milliseconds: 700));
    // Both bumps folded into one round.
    expect(rounds, ['third-node']);
  });

  test('filesDedupeKey normalizes WebDAV and leaves local folders out', () {
    final webdav = _filesRecord('w0123456789abcdef', 'Cloud', connections: [
      ServerConnection(uri: Uri.parse('HTTPS://Dav.Example.org/files/')),
    ]);
    expect(filesDedupeKey(webdav),
        normalizeWebDavUrl(Uri.parse('HTTPS://Dav.Example.org/files/')));
    expect(filesDedupeKey(_filesRecord(kFilesLocalAccountId, 'Here')), isNull);
  });

  test('pages_stay_under_budget_and_cover_every_record', () async {
    final roots = <LibraryRoot>[];
    final files = <IndexedFile>[];
    final groups = <GroupMatch>[];
    final movies = <MatchedMovie>[];
    final shows = <MatchedShow>[];
    String? cursor;
    var pages = 0;
    do {
      final res = await ask(page(kFilesLocalAccountId, 0, cursor));
      expect(res, isA<FlutterPeerFilesResponse_IndexPage>());
      final p = res as FlutterPeerFilesResponse_IndexPage;
      final blobs = [
        ...p.page.roots,
        ...p.page.files,
        ...p.page.groups,
        ...p.page.movies,
        ...p.page.shows,
      ];
      expect(blobs.fold<int>(0, (s, b) => s + b.length),
          lessThanOrEqualTo(64 * 1024));
      roots.addAll(decodeJsonRecords(p.page.roots, LibraryRoot.fromMap));
      files.addAll(decodeJsonRecords(p.page.files, IndexedFile.fromMap));
      groups.addAll(decodeJsonRecords(p.page.groups, GroupMatch.fromMap));
      movies.addAll(decodeJsonRecords(p.page.movies, MatchedMovie.fromMap));
      shows.addAll(decodeJsonRecords(p.page.shows, MatchedShow.fromMap));
      cursor = p.nextCursor;
      pages++;
    } while (cursor != null);

    expect(pages, greaterThan(1));
    Map<String, Map<String, dynamic>> byKey<T>(Iterable<T> xs,
            String Function(T) key, Map<String, dynamic> Function(T) toMap) =>
        {for (final x in xs) key(x): toMap(x).cast<String, dynamic>()};
    expect(byKey(roots, (r) => r.id, (r) => r.toMap()),
        byKey(localIndex.roots(), (r) => r.id, (r) => r.toMap()));
    expect(files, hasLength(2000));
    expect(byKey(files, (f) => f.key, (f) => f.toMap()),
        byKey(localIndex.files().values, (f) => f.key, (f) => f.toMap()));
    expect(groups, hasLength(300));
    expect(movies, hasLength(50));
    expect(shows.single.toMap(), localIndex.show(9100)!.toMap());

    // Exactly once each: the counts match the index and no key repeats.
    expect(roots, hasLength(localIndex.roots().length));
    expect(roots.map((r) => r.id).toSet(), hasLength(roots.length));
    expect(files.map((f) => f.key).toSet(), hasLength(files.length));
    expect(groups, hasLength(localIndex.groups().length));
    expect(groups.map((g) => g.groupKey).toSet(), hasLength(groups.length));
    expect(byKey(groups, (g) => g.groupKey, (g) => g.toMap()),
        byKey(localIndex.groups(), (g) => g.groupKey, (g) => g.toMap()));
    expect(movies, hasLength(localIndex.movies().length));
    expect(movies.map((m) => m.tmdbId).toSet(), hasLength(movies.length));
    expect(byKey(movies, (m) => '${m.tmdbId}', (m) => m.toMap()),
        byKey(localIndex.movies(), (m) => '${m.tmdbId}', (m) => m.toMap()));
    expect(shows, hasLength(localIndex.shows().length));
  });

  test('stale_revision_when_scan_finishes_mid_fetch', () async {
    final first = await ask(page(kFilesLocalAccountId, 0));
    final next = (first as FlutterPeerFilesResponse_IndexPage).nextCursor;
    expect(next, isNotNull);
    await host.bumpRevision(kFilesLocalAccountId);
    expect(await ask(page(kFilesLocalAccountId, 0, next)),
        const FlutterPeerFilesResponse.staleRevision());
    expect(await ask(page(kFilesLocalAccountId, 1, next)),
        isA<FlutterPeerFilesResponse_IndexPage>());
  });

  test('an index page of an account that is not shared is stale', () async {
    expect(await ask(page('p0123456789ab_flocal', 0)),
        const FlutterPeerFilesResponse.staleRevision());
  });

  test('grant_refuses_path_outside_index', () async {
    expect(await grant(kFilesLocalAccountId, '/etc/passwd'), notShared);
    expect(await grant(kFilesLocalAccountId, '../x'), notShared);
    // The relative path as stored is not the form a read names.
    expect(
        await grant(kFilesLocalAccountId, 'The Copper Lantern 0/Lantern 0.mkv'),
        notShared);
    // Another account's file.
    expect(await grant(kFilesLocalAccountId, '/Media/Harbor Kites.mkv'),
        notShared);
    expect(
        await grant(
            _smbAccount, '/media/films/The Copper Lantern 0/Lantern 0.mkv'),
        notShared);
    expect(backend.played, isEmpty);
  });

  test('grant answers an indexed file with the backend url and headers',
      () async {
    const path = '/media/films/The Copper Lantern 0/Lantern 0.mkv';
    final g = await grant(kFilesLocalAccountId, path);
    expect(g, isA<FlutterPeerFileGrantAnswer_Granted>());
    final granted = (g as FlutterPeerFileGrantAnswer_Granted).grant;
    expect(granted.url, contains(Uri.encodeComponent(path)));
    expect(granted.headers, [('Authorization', 'Basic abc')]);
    expect(backend.played, [path]);
  });

  test('a backend failure is a failed grant, a gone file is not shared',
      () async {
    const path = '/media/films/The Copper Lantern 0/Lantern 0.mkv';
    // The share is down: the file is there, so the viewer must not be told
    // it is gone.
    backend.failure = const BackendUnreachable('down');
    expect(await grant(kFilesLocalAccountId, path), failed);
    backend.failure = const BackendUnauthorized('password changed');
    expect(await grant(kFilesLocalAccountId, path), failed);
    backend.failure = const BackendNotFound('deleted since the scan');
    expect(await grant(kFilesLocalAccountId, path), notShared);
  });

  test('a lent account whose backend cannot be built is a failed grant',
      () async {
    backendMissing = true;
    expect(
        await grant(kFilesLocalAccountId,
            '/media/films/The Copper Lantern 0/Lantern 0.mkv'),
        failed);
  });

  test('grant_allows_sidecar_of_indexed_file', () async {
    // File 7 sits under the second root, `rshows`. The form authorized is
    // the one the files source hands `playable()` for a subtitle.
    const root = LibraryRoot(
        id: 'rshows',
        path: '/media/series',
        kind: FilesLibraryKind.mixed,
        title: 'rshows');
    final path =
        filesBackendPath(root, 'The Copper Lantern 7/Lantern 7.en.srt');
    expect(path, '/media/series/The Copper Lantern 7/Lantern 7.en.srt');
    expect(await grant(kFilesLocalAccountId, path),
        isA<FlutterPeerFileGrantAnswer_Granted>());
    expect(backend.played, [path]);
  });

  test('members_pushed_on_state_change_and_cleared_on_leave', () async {
    expect(transport.members.last, [_viewerNode]);

    await store.putMember(const PeerMember(
      nodeId: 'third-node',
      deviceName: 'third',
      platform: 'linux',
      updatedAt: 2,
    ));
    await sync.revokePeer(_viewerNode);
    await pumpEventQueue();
    expect(transport.members.last, ['third-node']);

    await sync.leaveGroup();
    await pumpEventQueue();
    expect(transport.members.last, isEmpty);
  });

  test('a failed allowlist push is retried on the next state change', () async {
    expect(transport.members.last, [_viewerNode]);
    transport.failMembers = true;
    await sync.revokePeer(_viewerNode);
    await pumpEventQueue();
    expect(transport.members.last, isEmpty);
    final attempts = transport.members.length;

    // Same roster, but Rust never took the list: it goes again.
    transport.failMembers = false;
    await sync.revokePeer(_viewerNode);
    await pumpEventQueue();
    expect(transport.members.length, greaterThan(attempts));
    expect(transport.members.last, isEmpty);

    // Once taken, an unchanged list is not pushed again.
    final settled = transport.members.length;
    await sync.revokePeer(_viewerNode);
    await pumpEventQueue();
    expect(transport.members.length, settled);
  });

  test('a revocation during a push is pushed once that push lands', () async {
    expect(transport.members.last, [_viewerNode]);
    for (final id in ['third-node', 'fourth-node']) {
      await store.putMember(PeerMember(
        nodeId: id,
        deviceName: id,
        platform: 'linux',
        updatedAt: 2,
      ));
    }
    final gate = transport.membersGate = Completer<void>();
    await sync.revokePeer('fourth-node');
    await pumpEventQueue();
    expect(transport.members.last..sort(), [_viewerNode, 'third-node']..sort());

    // Back to the list Rust held before the push in flight: it must still
    // go, since that push is about to replace it.
    await sync.revokePeer('third-node');
    await pumpEventQueue();
    transport.membersGate = null;
    gate.complete();
    await pumpEventQueue();

    expect(transport.members.last, [_viewerNode]);
  });

  test('bump_invalidates_rust_grants', () async {
    await host.bumpRevision(kFilesLocalAccountId);
    expect(transport.invalidated, [kFilesLocalAccountId]);
    expect(revisions.revision(kFilesLocalAccountId), 1);
  });

  test('a bumped revision persists in its Hive box', () async {
    final box = await Hive.openBox<int>(HivePeerFilesRevisions.boxName);
    final stored = HivePeerFilesRevisions(box, nowMs: () => 0);
    expect(await stored.bump(_smbAccount), 1);
    expect(await stored.bump(_smbAccount), 2);
    expect(HivePeerFilesRevisions(box).revision(_smbAccount), 2);
    expect(stored.revision(kFilesLocalAccountId), 0);
  });

  test('revisions never repeat across a reset store', () async {
    var now = 1700000000000;
    // Three bumps inside one millisecond still each move forward.
    final first = InMemoryPeerFilesRevisions(nowMs: () => now);
    final handedOut = [
      for (var i = 0; i < 3; i++) await first.bump(_smbAccount),
    ];
    expect(handedOut, [now, now + 1, now + 2]);

    // The in-memory fallback starts over on the next launch, as a box does
    // after a reinstall. A viewer still holds the old numbers, so the new
    // ones must all be past them.
    now += 1000;
    final reset = InMemoryPeerFilesRevisions(nowMs: () => now);
    expect(await reset.bump(_smbAccount), greaterThan(handedOut.last));

    final box = await Hive.openBox<int>('${HivePeerFilesRevisions.boxName}_r');
    expect(await HivePeerFilesRevisions(box, nowMs: () => now).bump('a'), now);
    // A clock that went backwards still moves the counter forward.
    expect(
        await HivePeerFilesRevisions(box, nowMs: () => 5).bump('a'), now + 1);
  });
}
