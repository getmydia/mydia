/// One stored credential with everything it owns, as persisted.
library;

import 'package:flutter/foundation.dart';

import '../source.dart';

@immutable
class SourceAccountRecord {
  SourceAccountRecord({
    required this.account,
    required this.profiles,
    required this.servers,
    required this.addedAtMs,
    this.chosenServerIds,
    this.serverLocks = const {},
  }) {
    final ids = [
      account.id,
      account.activeProfileId,
      for (final p in profiles) ...[p.id, p.accountId],
      for (final s in servers) ...[s.id, s.profileId, s.accountId],
      ...?chosenServerIds,
      ...serverLocks.keys,
    ];
    for (final id in ids) {
      if (!isValidSourceIdComponent(id)) {
        throw ArgumentError.value(id, 'id', 'not a valid source id component');
      }
    }
  }

  factory SourceAccountRecord.fromJson(Map<String, dynamic> json) =>
      SourceAccountRecord(
        account: ProviderAccount.fromJson(
            (json['account'] as Map).cast<String, dynamic>()),
        profiles: [
          for (final p in json['profiles'] as List)
            SourceProfile.fromJson((p as Map).cast<String, dynamic>()),
        ],
        servers: [
          for (final s in json['servers'] as List)
            SourceServer.fromJson((s as Map).cast<String, dynamic>()),
        ],
        addedAtMs: json['addedAtMs'] as int,
        chosenServerIds: (json['chosenServerIds'] as List?)?.cast<String>(),
        serverLocks: {
          for (final MapEntry(:key, :value)
              in ((json['serverLocks'] as Map?) ?? const {}).entries)
            // A value this build does not know came from a newer one: keep
            // the server out of sight rather than unlock it.
            key as String:
                SourceLock.values.asNameMap()[value] ?? SourceLock.hidden,
        }..removeWhere((_, lock) => lock == SourceLock.none),
      );

  final ProviderAccount account;
  final List<SourceProfile> profiles;
  final List<SourceServer> servers;
  final int addedAtMs;

  /// The servers the viewer picked for a Plex account, by machine id. Each
  /// Home user is shown the ones they can see. Null on records written
  /// before Plex Home: [chosenServers] then reads the stored servers.
  final List<String>? chosenServerIds;

  /// Lock mode per server id. Never holds [SourceLock.none]; a server that
  /// is absent is unlocked. Kept for every Home user of a Plex account,
  /// since the lock belongs to the server, not the profile.
  final Map<String, SourceLock> serverLocks;

  SourceLock lockOf(String serverId) =>
      serverLocks[serverId] ?? SourceLock.none;

  List<String> get chosenServers =>
      chosenServerIds ?? [for (final s in servers) s.id];

  /// Every server the account still lists, as a [Source].
  List<Source> get sources => [
        for (final server in servers)
          if (!server.gone)
            for (final profile in profiles)
              if (profile.id == server.profileId)
                Source(account: account, profile: profile, server: server),
      ];

  SourceAccountRecord copyWith({
    ProviderAccount? account,
    List<SourceProfile>? profiles,
    List<SourceServer>? servers,
    List<String>? chosenServerIds,
    Map<String, SourceLock>? serverLocks,
  }) =>
      SourceAccountRecord(
        account: account ?? this.account,
        profiles: profiles ?? this.profiles,
        servers: servers ?? this.servers,
        addedAtMs: addedAtMs,
        chosenServerIds: chosenServerIds ?? this.chosenServerIds,
        serverLocks: serverLocks ?? this.serverLocks,
      );

  Map<String, dynamic> toJson() => {
        'account': account.toJson(),
        'profiles': [for (final p in profiles) p.toJson()],
        'servers': [for (final s in servers) s.toJson()],
        'addedAtMs': addedAtMs,
        if (chosenServerIds != null) 'chosenServerIds': chosenServerIds,
        if (serverLocks.isNotEmpty)
          'serverLocks': {
            for (final e in serverLocks.entries) e.key: e.value.name,
          },
      };
}

@immutable
class SourceSnapshot {
  const SourceSnapshot({
    required this.accounts,
    this.activeId,
    this.allServers = const {},
  });

  static const empty = SourceSnapshot(accounts: []);

  /// Oldest first.
  final List<SourceAccountRecord> accounts;
  final SourceId? activeId;

  /// The viewer's "Include in All servers" choices. A source with no entry
  /// takes its kind's default. Lives beside the accounts so home Mydia,
  /// which has no record, can have one.
  final Map<SourceId, bool> allServers;
}
