/// The read model behind the Settings "Servers & devices" card and the hub:
/// every saved server and every paired device, reduced to what a row shows.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/p2p/peer_sync_service.dart';
import '../../../core/sources/all_servers_inclusion.dart';
import '../../../core/sources/lock/source_lock_controller.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/sources/store/source_records.dart';

enum ConnectionStatus { online, offline, needsSignIn }

@immutable
class ConnectionServer {
  const ConnectionServer({
    required this.record,
    required this.kind,
    required this.name,
    required this.host,
    required this.serverCount,
    required this.status,
    required this.locked,
    required this.inAllServers,
  });

  final SourceAccountRecord record;
  final SourceKind kind;
  final String name;

  /// The Mydia server URL host, read from the saved connection (no secrets).
  /// Null for other kinds and when no connection is stored.
  final String? host;
  final int serverCount;
  final ConnectionStatus status;

  /// Any of the account's servers has a lock other than [SourceLock.none].
  final bool locked;

  /// Any of the account's sources is included in All servers.
  final bool inAllServers;

  ProviderAccount get account => record.account;

  @override
  bool operator ==(Object other) =>
      other is ConnectionServer &&
      other.record == record &&
      other.kind == kind &&
      other.name == name &&
      other.host == host &&
      other.serverCount == serverCount &&
      other.status == status &&
      other.locked == locked &&
      other.inAllServers == inAllServers;

  @override
  int get hashCode => Object.hash(
      record, kind, name, host, serverCount, status, locked, inAllServers);
}

@immutable
class ConnectionDevice {
  const ConnectionDevice({
    required this.nodeId,
    required this.name,
    required this.platform,
    required this.lastSyncedAt,
  });

  final String nodeId;
  final String name;
  final String platform;
  final DateTime? lastSyncedAt;

  @override
  bool operator ==(Object other) =>
      other is ConnectionDevice &&
      other.nodeId == nodeId &&
      other.name == name &&
      other.platform == platform &&
      other.lastSyncedAt == lastSyncedAt;

  @override
  int get hashCode => Object.hash(nodeId, name, platform, lastSyncedAt);
}

@immutable
class ConnectionsOverview {
  const ConnectionsOverview({
    required this.localName,
    required this.localPlatform,
    required this.servers,
    required this.devices,
    required this.isPaired,
    required this.serversFailed,
    this.serversLoading = false,
  });

  final String localName;
  final String localPlatform;
  final List<ConnectionServer> servers;
  final List<ConnectionDevice> devices;
  final bool isPaired;
  final bool serversFailed;

  /// The saved servers have not been read yet. [servers] is empty then
  /// because nothing is known, not because nothing is saved.
  final bool serversLoading;

  int get onlineCount =>
      servers.where((s) => s.status == ConnectionStatus.online).length;

  @override
  bool operator ==(Object other) =>
      other is ConnectionsOverview &&
      other.localName == localName &&
      other.localPlatform == localPlatform &&
      listEquals(other.servers, servers) &&
      listEquals(other.devices, devices) &&
      other.isPaired == isPaired &&
      other.serversFailed == serversFailed &&
      other.serversLoading == serversLoading;

  @override
  int get hashCode => Object.hash(
      localName,
      localPlatform,
      Object.hashAll(servers),
      Object.hashAll(devices),
      isPaired,
      serversFailed,
      serversLoading);
}

IconData connectionPlatformIcon(String platform) {
  switch (platform.toLowerCase()) {
    case 'android':
      return Icons.phone_android;
    case 'ios':
      return Icons.phone_iphone;
    case 'macos':
      return Icons.laptop_mac;
    case 'windows':
      return Icons.desktop_windows;
    case 'linux':
      return Icons.computer;
    default:
      return Icons.devices;
  }
}

/// Re-reads the overview whenever the peer sync state changes. A counter
/// rather than `void`: `AsyncData(null) == AsyncData(null)`, so a void tick
/// would notify only once.
final _peerSyncTickProvider = StreamProvider<int>((ref) {
  var tick = 0;
  return ref.watch(peerSyncServiceProvider).onStateChanged.map((_) => ++tick);
});

final connectionsOverviewProvider = Provider<ConnectionsOverview>((ref) {
  final records = ref.watch(sourceRecordsProvider);
  final unlocked = ref.watch(sourceLockProvider);
  final store = ref.watch(peerSyncStoreProvider);
  final roster = ref.watch(peerGroupRosterProvider);
  final service = ref.watch(peerSyncServiceProvider);
  final choices = ref.watch(allServersChoicesProvider);
  ref.watch(_peerSyncTickProvider);

  final servers = <ConnectionServer>[];
  var failed = false;
  switch (records) {
    case AsyncData(:final value):
      for (final r in value.accounts) {
        final hidden = r.servers.isNotEmpty &&
            r.servers.every((sv) => r.lockOf(sv.id) == SourceLock.hidden);
        if (!unlocked && hidden) continue;
        servers.add(_serverOf(r, choices));
      }
    case AsyncError():
      failed = true;
    default:
      break;
  }
  final loading = records is AsyncLoading && !records.hasValue;

  final local = (roster.localNodeId() ?? '').toLowerCase();
  final devices = [
    for (final m in store.members().values)
      if (!m.revoked && m.nodeId.toLowerCase() != local)
        ConnectionDevice(
          nodeId: m.nodeId,
          name: m.deviceName,
          platform: m.platform,
          lastSyncedAt: switch (store.watermark(m.nodeId)) {
            final w? => DateTime.fromMillisecondsSinceEpoch(w.lastSyncedAt),
            null => null,
          },
        ),
  ];

  return ConnectionsOverview(
    localName: service.deviceName,
    localPlatform: service.platform,
    servers: servers,
    devices: devices,
    isPaired: service.isPaired || devices.isNotEmpty,
    serversFailed: failed,
    serversLoading: loading,
  );
});

ConnectionServer _serverOf(SourceAccountRecord r, Map<SourceId, bool> choices) {
  final live = [
    for (final s in r.servers)
      if (!s.gone) s
  ];
  final ConnectionStatus status;
  if (r.account.needsReauth) {
    status = ConnectionStatus.needsSignIn;
  } else if (r.servers.isNotEmpty &&
      r.servers.every((s) => s.gone || !s.presence)) {
    status = ConnectionStatus.offline;
  } else {
    status = ConnectionStatus.online;
  }
  String? host;
  if (r.account.kind == SourceKind.mydia) {
    for (final s in live) {
      for (final c in s.connections) {
        if (c.uri.host.isNotEmpty) {
          host = c.uri.host;
          break;
        }
      }
      if (host != null) break;
    }
  }
  return ConnectionServer(
    record: r,
    kind: r.account.kind,
    name: r.account.displayName,
    host: host,
    serverCount: live.length,
    status: status,
    locked: r.servers.any((s) => r.lockOf(s.id) != SourceLock.none),
    inAllServers: r.sources.any((s) => includedInAllServers(s, choices)),
  );
}
