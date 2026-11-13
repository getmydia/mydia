/// Builders shared by the hub tests: a recording [SettingsNav] and the
/// overview, server and device fixtures.
library;

import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/presentation/screens/connections/connections_overview.dart';
import 'package:player/presentation/screens/settings/settings_nav.dart';

class RecordingNav implements SettingsNav {
  final calls = <String>[];
  @override
  void openInstance(SourceId id) => calls.add('instance ${id.value}');
  @override
  void openDiagnostics() => calls.add('diagnostics');
  @override
  void openPairedDevices() => calls.add('paired-devices');
  @override
  void openConnections() => calls.add('connections');
  @override
  void openAccount(String accountId) => calls.add('account $accountId');
  @override
  void accountRemoved() => calls.add('account-removed');
  @override
  void instanceRemoved() => calls.add('removed');
  @override
  void addServer() => calls.add('add');
  @override
  void reauth(SourceKind kind, String accountId) =>
      calls.add('reauth ${kind.name} $accountId');
  @override
  void switchedTo(SourceId id) => calls.add('switched ${id.value}');
}

/// One account with an owner profile on server `srv`, plus a `kid` profile
/// on server `srv-kid` when [kidProfile] is set.
SourceAccountRecord hubRecord(String id, String name, SourceKind kind,
        {bool kidProfile = false}) =>
    SourceAccountRecord(
      account: ProviderAccount(
        id: id,
        kind: kind,
        displayName: name,
        storageNamespace: 'source/$id',
        activeProfileId: 'owner',
      ),
      profiles: [
        SourceProfile(id: 'owner', accountId: id, name: 'o', isOwner: true),
        if (kidProfile)
          SourceProfile(id: 'kid', accountId: id, name: 'k', isOwner: false),
      ],
      servers: [
        SourceServer(
          id: 'srv',
          accountId: id,
          profileId: 'owner',
          name: name,
          presence: true,
        ),
        if (kidProfile)
          SourceServer(
            id: 'srv-kid',
            accountId: id,
            profileId: 'kid',
            name: name,
            presence: true,
          ),
      ],
      addedAtMs: 0,
    );

ConnectionServer hubServer(
  String id,
  String name, {
  SourceKind kind = SourceKind.mydia,
  ConnectionStatus status = ConnectionStatus.online,
  String? host,
  bool locked = false,
  bool inAllServers = false,
  bool kidProfile = false,
}) =>
    ConnectionServer(
      record: hubRecord(id, name, kind, kidProfile: kidProfile),
      kind: kind,
      name: name,
      host: host,
      serverCount: 1,
      status: status,
      locked: locked,
      inAllServers: inAllServers,
    );

ConnectionDevice hubDevice(String id, String name, String platform) =>
    ConnectionDevice(
      nodeId: id,
      name: name,
      platform: platform,
      lastSyncedAt: DateTime.now().subtract(const Duration(minutes: 5)),
    );

ConnectionsOverview hubOverview({
  List<ConnectionServer> servers = const [],
  List<ConnectionDevice> devices = const [],
  bool? isPaired,
  bool serversLoading = false,
}) =>
    ConnectionsOverview(
      localName: 'Living room TV',
      localPlatform: 'linux',
      servers: servers,
      devices: devices,
      isPaired: isPaired ?? devices.isNotEmpty,
      serversFailed: false,
      serversLoading: serversLoading,
    );
