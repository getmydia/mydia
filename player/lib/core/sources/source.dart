/// Where the player's media comes from: a Mydia, Plex, Stash or Jellyfin server.
///
/// Three levels, so a change to one never reshapes the others. A
/// [ProviderAccount] is a credential, a [SourceProfile] is who acts with it
/// (a Plex Home user, later), and a [SourceServer] is what the viewer
/// browses. A [Source] is one of each, and is what the switcher lists and
/// routes address.
library;

import 'package:flutter/foundation.dart';

enum SourceKind { mydia, plex, stash, jellyfin }

/// Storage namespace of the one Mydia login that predates sources. Its
/// credentials stay under `AuthService`'s original keys, unmigrated.
const kLegacyStorageNamespace = 'legacy';

final _sourceIdComponent = RegExp(r'^[A-Za-z0-9_-]+$');

/// Whether [value] may be an account, profile or server id. `SourceId`
/// joins the three with `:`, and routes carry it as a path segment, so
/// neither separator may appear inside one.
bool isValidSourceIdComponent(String value) =>
    _sourceIdComponent.hasMatch(value);

/// Stable identity of a [Source]. Caches, memories and routes key on it.
@immutable
class SourceId {
  const SourceId(this.value);

  final String value;

  /// The single Mydia login read from `AuthService`.
  static const legacyMydia = SourceId('mydia');

  @override
  bool operator ==(Object other) => other is SourceId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

/// A credential: one plex.tv identity, one Stash API key, one Mydia login.
@immutable
class ProviderAccount {
  const ProviderAccount({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.storageNamespace,
    required this.activeProfileId,
    this.needsReauth = false,
  });

  factory ProviderAccount.fromJson(Map<String, dynamic> json) =>
      ProviderAccount(
        id: json['id'] as String,
        kind: SourceKind.values.byName(json['kind'] as String),
        displayName: json['displayName'] as String,
        storageNamespace: json['storageNamespace'] as String,
        activeProfileId: json['activeProfileId'] as String,
        needsReauth: json['needsReauth'] as bool? ?? false,
      );

  final String id;
  final SourceKind kind;
  final String displayName;

  /// Prefix of every secure-storage key this account owns.
  final String storageNamespace;
  final String activeProfileId;

  /// The server refused the saved credential. Nothing is deleted; the
  /// switcher offers "Sign in again".
  final bool needsReauth;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'displayName': displayName,
        'storageNamespace': storageNamespace,
        'activeProfileId': activeProfileId,
        'needsReauth': needsReauth,
      };

  ProviderAccount copyWith({String? displayName, bool? needsReauth}) =>
      ProviderAccount(
        id: id,
        kind: kind,
        displayName: displayName ?? this.displayName,
        storageNamespace: storageNamespace,
        activeProfileId: activeProfileId,
        needsReauth: needsReauth ?? this.needsReauth,
      );

  @override
  bool operator ==(Object other) =>
      other is ProviderAccount &&
      other.id == id &&
      other.kind == kind &&
      other.displayName == displayName &&
      other.storageNamespace == storageNamespace &&
      other.activeProfileId == activeProfileId &&
      other.needsReauth == needsReauth;

  @override
  int get hashCode => Object.hash(
      id, kind, displayName, storageNamespace, activeProfileId, needsReauth);
}

/// Who is acting. Mydia and Stash always have exactly one, the owner.
@immutable
class SourceProfile {
  const SourceProfile({
    required this.id,
    required this.accountId,
    required this.name,
    required this.isOwner,
  });

  factory SourceProfile.fromJson(Map<String, dynamic> json) => SourceProfile(
        id: json['id'] as String,
        accountId: json['accountId'] as String,
        name: json['name'] as String,
        isOwner: json['isOwner'] as bool,
      );

  final String id;
  final String accountId;
  final String name;
  final bool isOwner;

  Map<String, dynamic> toJson() =>
      {'id': id, 'accountId': accountId, 'name': name, 'isOwner': isOwner};

  @override
  bool operator ==(Object other) =>
      other is SourceProfile &&
      other.id == id &&
      other.accountId == accountId &&
      other.name == name &&
      other.isOwner == isOwner;

  @override
  int get hashCode => Object.hash(id, accountId, name, isOwner);
}

/// One way to reach a server. Plex advertises several (LAN, WAN, relay);
/// Stash has exactly one, the URL the viewer typed.
@immutable
class ServerConnection {
  const ServerConnection({
    required this.uri,
    this.local = false,
    this.relay = false,
  });

  factory ServerConnection.fromJson(Map<String, dynamic> json) =>
      ServerConnection(
        uri: Uri.parse(json['uri'] as String),
        local: json['local'] as bool? ?? false,
        relay: json['relay'] as bool? ?? false,
      );

  final Uri uri;
  final bool local;
  final bool relay;

  Map<String, dynamic> toJson() =>
      {'uri': uri.toString(), 'local': local, 'relay': relay};

  @override
  bool operator ==(Object other) =>
      other is ServerConnection &&
      other.uri == uri &&
      other.local == local &&
      other.relay == relay;

  @override
  int get hashCode => Object.hash(uri, local, relay);
}

/// What the viewer browses. One Plex account yields many.
@immutable
class SourceServer {
  const SourceServer({
    required this.id,
    required this.accountId,
    required this.profileId,
    required this.name,
    this.machineIdentifier,
    this.owned = true,
    this.presence = true,
    this.gone = false,
    this.httpsRequired = false,
    this.connections = const [],
  });

  factory SourceServer.fromJson(Map<String, dynamic> json) => SourceServer(
        id: json['id'] as String,
        accountId: json['accountId'] as String,
        profileId: json['profileId'] as String,
        name: json['name'] as String,
        machineIdentifier: json['machineIdentifier'] as String?,
        owned: json['owned'] as bool? ?? true,
        presence: json['presence'] as bool? ?? true,
        gone: json['gone'] as bool? ?? false,
        httpsRequired: json['httpsRequired'] as bool? ?? false,
        connections: [
          for (final c in (json['connections'] as List? ?? const []))
            ServerConnection.fromJson((c as Map).cast<String, dynamic>()),
        ],
      );

  final String id;
  final String accountId;
  final String profileId;
  final String name;

  /// Plex's id for the server, which `/identity` must echo back.
  final String? machineIdentifier;

  /// False for a Plex server shared with this account by someone else.
  final bool owned;

  /// Plex's own online flag for the server, from the last discovery.
  final bool presence;

  /// The account no longer lists this server. Kept, not deleted.
  final bool gone;

  /// Plex refuses plain HTTP to this server, even on the LAN.
  final bool httpsRequired;
  final List<ServerConnection> connections;

  Map<String, dynamic> toJson() => {
        'id': id,
        'accountId': accountId,
        'profileId': profileId,
        'name': name,
        'machineIdentifier': machineIdentifier,
        'owned': owned,
        'presence': presence,
        'gone': gone,
        'httpsRequired': httpsRequired,
        'connections': [for (final c in connections) c.toJson()],
      };

  SourceServer copyWith({
    String? name,
    bool? presence,
    bool? gone,
    List<ServerConnection>? connections,
  }) =>
      SourceServer(
        id: id,
        accountId: accountId,
        profileId: profileId,
        name: name ?? this.name,
        machineIdentifier: machineIdentifier,
        owned: owned,
        presence: presence ?? this.presence,
        gone: gone ?? this.gone,
        httpsRequired: httpsRequired,
        connections: connections ?? this.connections,
      );

  @override
  bool operator ==(Object other) =>
      other is SourceServer &&
      other.id == id &&
      other.accountId == accountId &&
      other.profileId == profileId &&
      other.name == name &&
      other.machineIdentifier == machineIdentifier &&
      other.owned == owned &&
      other.presence == presence &&
      other.gone == gone &&
      other.httpsRequired == httpsRequired &&
      listEquals(other.connections, connections);

  @override
  int get hashCode => Object.hash(
      id,
      accountId,
      profileId,
      name,
      machineIdentifier,
      owned,
      presence,
      gone,
      httpsRequired,
      Object.hashAll(connections));
}

@immutable
class Source {
  const Source({
    required this.account,
    required this.profile,
    required this.server,
  });

  /// The Mydia login `AuthService` already holds. Nothing is read from
  /// storage here: the keys stay where they are, under
  /// [kLegacyStorageNamespace].
  factory Source.legacyMydia() => const Source(
        account: ProviderAccount(
          id: 'mydia',
          kind: SourceKind.mydia,
          displayName: 'Mydia',
          storageNamespace: kLegacyStorageNamespace,
          activeProfileId: 'owner',
        ),
        profile: SourceProfile(
          id: 'owner',
          accountId: 'mydia',
          name: 'Owner',
          isOwner: true,
        ),
        server: SourceServer(
          id: 'mydia',
          accountId: 'mydia',
          profileId: 'owner',
          name: 'Mydia',
        ),
      );

  final ProviderAccount account;
  final SourceProfile profile;
  final SourceServer server;

  SourceId get id => account.storageNamespace == kLegacyStorageNamespace
      ? SourceId.legacyMydia
      : SourceId('${account.id}:${profile.id}:${server.id}');

  SourceKind get kind => account.kind;

  String get displayName => server.name;

  @override
  bool operator ==(Object other) =>
      other is Source &&
      other.account == account &&
      other.profile == profile &&
      other.server == server;

  @override
  int get hashCode => Object.hash(account, profile, server);
}
