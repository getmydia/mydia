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
  }) {
    final ids = [
      account.id,
      account.activeProfileId,
      for (final p in profiles) p.id,
      for (final s in servers) s.id,
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
      );

  final ProviderAccount account;
  final List<SourceProfile> profiles;
  final List<SourceServer> servers;
  final int addedAtMs;

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
    List<SourceServer>? servers,
  }) =>
      SourceAccountRecord(
        account: account ?? this.account,
        profiles: profiles,
        servers: servers ?? this.servers,
        addedAtMs: addedAtMs,
      );

  Map<String, dynamic> toJson() => {
        'account': account.toJson(),
        'profiles': [for (final p in profiles) p.toJson()],
        'servers': [for (final s in servers) s.toJson()],
        'addedAtMs': addedAtMs,
      };
}

@immutable
class SourceSnapshot {
  const SourceSnapshot({required this.accounts, this.activeId});

  static const empty = SourceSnapshot(accounts: []);

  /// Oldest first.
  final List<SourceAccountRecord> accounts;
  final SourceId? activeId;
}
