import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_group_roster.dart';
import 'package:player/core/p2p/peer_sync_records.dart';
import 'package:player/core/p2p/peer_sync_service.dart';
import 'package:player/core/p2p/peer_sync_store.dart';
import 'package:player/core/sources/lock/source_lock_controller.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/presentation/screens/connections/connections_overview.dart';

class _Records extends SourceRecordsNotifier {
  _Records(this._value);
  final AsyncValue<SourceSnapshot> _value;

  @override
  Future<SourceSnapshot> build() async {
    final v = _value;
    if (v is AsyncError<SourceSnapshot>) throw Exception('boom');
    if (v is AsyncLoading<SourceSnapshot>) {
      return Completer<SourceSnapshot>().future;
    }
    return v.requireValue;
  }
}

class _Lock extends SourceLockController {
  _Lock(this._on);
  final bool _on;
  @override
  bool build() => _on;
}

class _Service implements PeerSyncService {
  // ignore: close_sinks
  final _c = StreamController<void>.broadcast();
  @override
  String get deviceName => 'Living room TV';
  @override
  String get platform => 'linux';
  @override
  bool get isPaired => false;
  @override
  Stream<void> get onStateChanged => _c.stream;
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

SourceAccountRecord _rec(
  String id, {
  String name = 'Home Mydia',
  bool presence = true,
  bool gone = false,
  bool needsReauth = false,
  SourceLock lock = SourceLock.none,
  SourceKind kind = SourceKind.mydia,
  String? url,
}) =>
    SourceAccountRecord(
      account: ProviderAccount(
        id: id,
        kind: kind,
        displayName: name,
        storageNamespace: 'source/$id',
        activeProfileId: 'owner',
        needsReauth: needsReauth,
      ),
      profiles: [
        SourceProfile(id: 'owner', accountId: id, name: 'o', isOwner: true),
      ],
      servers: [
        SourceServer(
          id: 'srv',
          accountId: id,
          profileId: 'owner',
          name: name,
          presence: presence,
          gone: gone,
          connections: [if (url != null) ServerConnection(uri: Uri.parse(url))],
        ),
      ],
      addedAtMs: 0,
      serverLocks: lock == SourceLock.none ? const {} : {'srv': lock},
    );

ProviderContainer _container({
  AsyncValue<SourceSnapshot>? records,
  bool unlocked = false,
  PeerSyncStore? store,
  String? localNodeId,
  List<SourceAccountRecord> accounts = const [],
  _Service? service,
}) {
  final st = store ?? InMemoryPeerSyncStore();
  final c = ProviderContainer(overrides: [
    sourceRecordsProvider.overrideWith(() =>
        _Records(records ?? AsyncData(SourceSnapshot(accounts: accounts)))),
    sourceLockProvider.overrideWith(() => _Lock(unlocked)),
    peerSyncStoreProvider.overrideWithValue(st),
    peerGroupRosterProvider.overrideWithValue(PeerGroupRoster(
        store: st,
        localNodeId: () => localNodeId,
        isPeerConnected: (_) => false)),
    peerSyncServiceProvider.overrideWithValue(service ?? _Service()),
  ]);
  addTearDown(c.dispose);
  return c;
}

Future<ConnectionsOverview> _read(ProviderContainer c) async {
  await c.read(sourceRecordsProvider.future).then((_) {}, onError: (_) {});
  return c.read(connectionsOverviewProvider);
}

PeerMember _member(String id, {bool revoked = false}) => PeerMember(
    nodeId: id,
    deviceName: 'Pixel phone',
    platform: 'android',
    updatedAt: 1,
    revoked: revoked);

void main() {
  test('status derivation', () async {
    final o = await _read(_container(accounts: [
      _rec('a'),
      _rec('b', presence: false),
      _rec('c', gone: true),
      _rec('d', needsReauth: true, presence: false),
    ]));
    expect(o.servers.map((s) => s.status), [
      ConnectionStatus.online,
      ConnectionStatus.offline,
      ConnectionStatus.offline,
      ConnectionStatus.needsSignIn,
    ]);
    expect(o.onlineCount, 1);
    expect(o.localName, 'Living room TV');
    expect(o.localPlatform, 'linux');
  });

  test('hidden accounts are excluded while locked', () async {
    final accounts = [
      _rec('a'),
      _rec('b', name: 'NAS', lock: SourceLock.hidden),
    ];
    final locked = await _read(_container(accounts: accounts));
    expect(locked.servers.length, 1);
    final open = await _read(_container(accounts: accounts, unlocked: true));
    expect(open.servers.length, 2);
    expect(open.servers.last.locked, isTrue);
    expect(open.servers.first.locked, isFalse);
  });

  test('host comes from the stored connection, mydia only', () async {
    final o = await _read(_container(accounts: [
      _rec('a', url: 'https://Home.example.com:8443/x'),
      _rec('b', kind: SourceKind.plex, url: 'https://plex.example.com'),
    ]));
    expect(o.servers.first.host, 'home.example.com');
    expect(o.servers.last.host, isNull);
    expect(o.servers.first.record.account.id, 'a');
    expect(o.servers.first.account.id, 'a');
  });

  test('devices exclude local and revoked members', () async {
    final store = InMemoryPeerSyncStore();
    await store.putMember(_member('LOCAL-node'));
    await store.putMember(_member('peer-1'));
    await store.putMember(_member('peer-2', revoked: true));
    final o = await _read(_container(store: store, localNodeId: 'local-NODE'));
    expect(o.devices.map((d) => d.nodeId), ['peer-1']);
    expect(o.isPaired, isTrue);
  });

  test('lastSyncedAt comes from the peer watermark', () async {
    final store = InMemoryPeerSyncStore();
    await store.putMember(_member('peer-1'));
    await store.putMember(_member('peer-2'));
    await store.setWatermark(
        'peer-1',
        const PeerWatermark(
            lastSentLandedAt: 0,
            lastPeerNowMs: 0,
            lastSyncedAt: 1700000000000));
    final o = await _read(_container(store: store, localNodeId: 'x'));
    final byId = {for (final d in o.devices) d.nodeId: d};
    expect(byId['peer-1']!.lastSyncedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(byId['peer-2']!.lastSyncedAt, isNull);
  });

  test('every peer sync change re-reads the devices', () async {
    final store = InMemoryPeerSyncStore();
    final service = _Service();
    final c = _container(store: store, localNodeId: 'x', service: service);
    final seen = <List<String>>[];
    c.listen<ConnectionsOverview>(connectionsOverviewProvider,
        (_, next) => seen.add([for (final d in next.devices) d.nodeId]),
        fireImmediately: true);
    await c.read(sourceRecordsProvider.future);
    await Future<void>.delayed(Duration.zero);

    await store.putMember(_member('peer-1'));
    service._c.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(connectionsOverviewProvider).devices.map((d) => d.nodeId),
        ['peer-1']);

    await store.putMember(_member('peer-2'));
    service._c.add(null);
    await Future<void>.delayed(Duration.zero);
    expect(c.read(connectionsOverviewProvider).devices.map((d) => d.nodeId),
        ['peer-1', 'peer-2']);
    expect(seen.last, ['peer-1', 'peer-2']);
  });

  test('records still loading sets serversLoading, not serversFailed', () {
    final c = _container(records: const AsyncLoading<SourceSnapshot>());
    final o = c.read(connectionsOverviewProvider);
    expect(o.servers, isEmpty);
    expect(o.serversLoading, isTrue);
    expect(o.serversFailed, isFalse);
  });

  test('loaded records clear serversLoading', () async {
    final o = await _read(_container(accounts: [_rec('a')]));
    expect(o.serversLoading, isFalse);
  });

  test('records error sets serversFailed', () async {
    final o = await _read(_container(
        records: const AsyncError<SourceSnapshot>('boom', StackTrace.empty)));
    expect(o.servers, isEmpty);
    expect(o.serversFailed, isTrue);
  });
}
