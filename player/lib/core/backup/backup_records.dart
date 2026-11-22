import 'dart:convert';

import 'backup_gzip.dart';

/// Plaintext data model of the end-to-end encrypted cloud backup.
///
/// Every record is last-writer-wins per [key] on its origin [updatedAt], with
/// tombstones ([deleted]) for removal. Keys are namespaced by record type so
/// different types never collide in [lwwMerge].
sealed class BackupRecord {
  const BackupRecord({
    required this.key,
    required this.updatedAt,
    this.deleted = false,
  });

  final String key;
  final int updatedAt;
  final bool deleted;

  String get type;

  /// Type specific fields, merged into [toJson].
  Map<String, dynamic> get fields;

  Map<String, dynamic> toJson() => {
    'type': type,
    'key': key,
    'updatedAt': updatedAt,
    'deleted': deleted,
    ...fields,
  };

  /// Returns null for an unknown `type`, so records written by a newer build
  /// are skipped rather than fatal. Throws a [TypeError] or [FormatException]
  /// when a known type is malformed.
  static const _knownTypes = {'watch', 'pin', 'account', 'setting', 'group'};

  static BackupRecord? fromJson(Map<String, dynamic> json) {
    if (!_knownTypes.contains(json['type'])) return null;
    final key = json['key'] as String;
    final updatedAt = (json['updatedAt'] as num).toInt();
    final deleted = json['deleted'] as bool? ?? false;
    switch (json['type']) {
      case 'watch':
        return WatchBackupRecord(
          key: key,
          watched: json['watched'] as bool,
          positionSeconds: (json['positionSeconds'] as num?)?.toInt(),
          durationSeconds: (json['durationSeconds'] as num?)?.toInt(),
          updatedAt: updatedAt,
          deleted: deleted,
        );
      case 'pin':
        return PinBackupRecord(
          key: key,
          groupKey: json['groupKey'] as String,
          isShow: json['isShow'] as bool,
          tmdbId: (json['tmdbId'] as num?)?.toInt(),
          pinned: json['pinned'] as bool,
          updatedAt: updatedAt,
          deleted: deleted,
        );
      case 'account':
        if (!key.startsWith(AccountBackupRecord.keyPrefix)) {
          throw FormatException('account record key $key');
        }
        return AccountBackupRecord(
          key: key,
          recordJson: Map<String, dynamic>.from(
            json['recordJson'] as Map<dynamic, dynamic>,
          ),
          secrets: Map<String, String>.from(
            json['secrets'] as Map<dynamic, dynamic>,
          ),
          updatedAt: updatedAt,
          deleted: deleted,
        );
      case 'setting':
        return SettingBackupRecord(
          key: key,
          settingKey: json['settingKey'] as String,
          value: json['value'] as String?,
          updatedAt: updatedAt,
          deleted: deleted,
        );
      case 'group':
        return GroupBackupRecord(
          key: key,
          groupSecretB64: json['groupSecretB64'] as String,
          nodeToSlot: Map<String, String>.from(
            json['nodeToSlot'] as Map<dynamic, dynamic>,
          ),
          updatedAt: updatedAt,
          deleted: deleted,
        );
      default:
        return null;
    }
  }

  /// Canonical JSON (recursively sorted keys), identical on every device.
  String canonicalJson() => jsonEncode(_sorted(toJson()));

  @override
  bool operator ==(Object other) =>
      other is BackupRecord && canonicalJson() == other.canonicalJson();

  @override
  int get hashCode => canonicalJson().hashCode;
}

Object? _sorted(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => k as String).toList()..sort();
    return {for (final k in keys) k: _sorted(v[k])};
  }
  if (v is List) return [for (final e in v) _sorted(e)];
  return v;
}

/// Same synced fields as `PeerWatchRecord`, minus `landedAt`. Key is the
/// canonical watch sync key.
class WatchBackupRecord extends BackupRecord {
  const WatchBackupRecord({
    required super.key,
    required this.watched,
    this.positionSeconds,
    this.durationSeconds,
    required super.updatedAt,
    super.deleted,
  });

  final bool watched;
  final int? positionSeconds;
  final int? durationSeconds;

  @override
  String get type => 'watch';

  @override
  Map<String, dynamic> get fields => {
    'watched': watched,
    'positionSeconds': positionSeconds,
    'durationSeconds': durationSeconds,
  };
}

/// Same synced fields as `PeerPinRecord`, minus `landedAt`. Key is
/// `pinSyncKey(isShow:, groupKey:)`.
class PinBackupRecord extends BackupRecord {
  const PinBackupRecord({
    required super.key,
    required this.groupKey,
    required this.isShow,
    this.tmdbId,
    required this.pinned,
    required super.updatedAt,
    super.deleted,
  });

  final String groupKey;
  final bool isShow;
  final int? tmdbId;
  final bool pinned;

  @override
  String get type => 'pin';

  @override
  Map<String, dynamic> get fields => {
    'groupKey': groupKey,
    'isShow': isShow,
    'tmdbId': tmdbId,
    'pinned': pinned,
  };
}

/// A source account. Key is `account:<accountId>`. [secrets] keys are storage
/// keys relative to the account's `storageNamespace`; the values are
/// credentials and never appear in [toString].
class AccountBackupRecord extends BackupRecord {
  const AccountBackupRecord({
    required super.key,
    required this.recordJson,
    required this.secrets,
    required super.updatedAt,
    super.deleted,
  });

  static const keyPrefix = 'account:';

  /// Derived from [key], so the two cannot drift.
  String get accountId => key.substring(keyPrefix.length);

  final Map<String, dynamic> recordJson;
  final Map<String, String> secrets;

  @override
  String get type => 'account';

  @override
  Map<String, dynamic> get fields => {
    'recordJson': recordJson,
    'secrets': secrets,
  };

  @override
  String toString() =>
      'AccountBackupRecord(key: $key, accountId: $accountId, '
      'secrets: <${secrets.length} redacted>, updatedAt: $updatedAt, '
      'deleted: $deleted)';
}

/// A player setting. Key is `setting:<settingKey>`.
class SettingBackupRecord extends BackupRecord {
  const SettingBackupRecord({
    required super.key,
    required this.settingKey,
    this.value,
    required super.updatedAt,
    super.deleted,
  });

  final String settingKey;
  final String? value;

  @override
  String get type => 'setting';

  @override
  Map<String, dynamic> get fields => {'settingKey': settingKey, 'value': value};
}

/// The p2p group secret. Key is `group`. [nodeToSlot] maps p2p node ids to
/// backup slot ids. The secret is a credential and stays out of [toString].
class GroupBackupRecord extends BackupRecord {
  const GroupBackupRecord({
    required super.key,
    required this.groupSecretB64,
    required this.nodeToSlot,
    required super.updatedAt,
    super.deleted,
  });

  final String groupSecretB64;
  final Map<String, String> nodeToSlot;

  @override
  String get type => 'group';

  @override
  Map<String, dynamic> get fields => {
    'groupSecretB64': groupSecretB64,
    'nodeToSlot': nodeToSlot,
  };

  @override
  String toString() =>
      'GroupBackupRecord(key: $key, nodes: ${nodeToSlot.length}, '
      'updatedAt: $updatedAt, deleted: $deleted)';
}

/// A payload written by a newer app build (`v` above [BackupPayload.version]).
class NewerBackupVersionException extends FormatException {
  NewerBackupVersionException(int found)
    : super(
        'backup payload version $found is newer than '
        '${BackupPayload.version}',
      );
}

class BackupPayload {
  const BackupPayload({
    required this.deviceName,
    required this.platform,
    required this.createdAt,
    required this.records,
    this.movedTo,
  });

  static const int version = 1;

  final String deviceName;
  final String platform;
  final int createdAt;
  final List<BackupRecord> records;

  /// Set when this device's backup now lives in another store (its id):
  /// the slot carries no records worth merging. Absent when null, so a
  /// build that predates the field reads the payload unchanged.
  final String? movedTo;

  List<int> encode() => gzipEncode(
    utf8.encode(
      jsonEncode({
        'v': version,
        'deviceName': deviceName,
        'platform': platform,
        'createdAt': createdAt,
        'records': [for (final r in records) r.toJson()],
        if (movedTo != null) 'movedTo': movedTo,
      }),
    ),
  );

  /// Throws [FormatException] for bad gzip, bad JSON, a wrong version
  /// ([NewerBackupVersionException] for a newer one) or a malformed record. Records of an unknown type are dropped.
  static BackupPayload decode(List<int> bytes) {
    try {
      final json = jsonDecode(utf8.decode(gzipDecode(bytes)));
      if (json is! Map<String, dynamic>) {
        throw const FormatException('backup payload is not an object');
      }
      final v = json['v'];
      if (v is int && v > version) throw NewerBackupVersionException(v);
      if (v != version) {
        throw FormatException(
          'unsupported backup payload version ${json['v']}',
        );
      }
      final records = <BackupRecord>[];
      for (final raw in json['records'] as List<dynamic>) {
        final r = BackupRecord.fromJson(raw as Map<String, dynamic>);
        if (r != null) records.add(r);
      }
      return BackupPayload(
        deviceName: json['deviceName'] as String,
        platform: json['platform'] as String,
        createdAt: (json['createdAt'] as num).toInt(),
        records: records,
        movedTo: json['movedTo'] as String?,
      );
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('invalid backup payload: ${e.runtimeType}');
    }
  }
}

/// Merges every device's records: per key the highest `updatedAt` wins, a
/// tombstone wins a tie, then the lexicographically larger canonical JSON, so
/// every device picks the same record regardless of input order. The result is
/// sorted by key.
List<BackupRecord> lwwMerge(Iterable<Iterable<BackupRecord>> slots) {
  final best = <String, BackupRecord>{};
  for (final slot in slots) {
    for (final r in slot) {
      final cur = best[r.key];
      if (cur == null || _beats(r, cur)) best[r.key] = r;
    }
  }
  final keys = best.keys.toList()..sort();
  return [for (final k in keys) best[k]!];
}

bool _beats(BackupRecord a, BackupRecord b) {
  if (a.updatedAt != b.updatedAt) return a.updatedAt > b.updatedAt;
  if (a.deleted != b.deleted) return a.deleted;
  return a.canonicalJson().compareTo(b.canonicalJson()) > 0;
}
