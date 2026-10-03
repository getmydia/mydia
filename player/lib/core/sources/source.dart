/// Where the player's media comes from: a Mydia, Plex or Stash server.
///
/// Three levels, so a change to one never reshapes the others. A
/// [ProviderAccount] is a credential, a [SourceProfile] is who acts with it
/// (a Plex Home user, later), and a [SourceServer] is what the viewer
/// browses. A [Source] is one of each, and is what the switcher lists and
/// routes address.
library;

import 'package:flutter/foundation.dart';

enum SourceKind { mydia, plex, stash }

/// Storage namespace of the one Mydia login that predates sources. Its
/// credentials stay under `AuthService`'s original keys, unmigrated.
const kLegacyStorageNamespace = 'legacy';

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
  });

  final String id;
  final SourceKind kind;
  final String displayName;

  /// Prefix of every secure-storage key this account owns.
  final String storageNamespace;
  final String activeProfileId;

  @override
  bool operator ==(Object other) =>
      other is ProviderAccount &&
      other.id == id &&
      other.kind == kind &&
      other.displayName == displayName &&
      other.storageNamespace == storageNamespace &&
      other.activeProfileId == activeProfileId;

  @override
  int get hashCode =>
      Object.hash(id, kind, displayName, storageNamespace, activeProfileId);
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

  final String id;
  final String accountId;
  final String name;
  final bool isOwner;

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

/// What the viewer browses. One Plex account yields many.
@immutable
class SourceServer {
  const SourceServer({
    required this.id,
    required this.accountId,
    required this.profileId,
    required this.name,
  });

  final String id;
  final String accountId;
  final String profileId;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is SourceServer &&
      other.id == id &&
      other.accountId == accountId &&
      other.profileId == profileId &&
      other.name == name;

  @override
  int get hashCode => Object.hash(id, accountId, profileId, name);
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
