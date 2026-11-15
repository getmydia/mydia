import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_ce/hive.dart';

/// Where [BackupMetaStore] keeps its entries: the Hive box
/// [BackupMetaStore.boxName], or a map in tests.
abstract interface class BackupMetaStorage {
  String? get(String key);
  Iterable<String> get keys;
  Future<void> put(String key, String value);
  Future<void> delete(String key);
}

class HiveBackupMetaStorage implements BackupMetaStorage {
  HiveBackupMetaStorage(this._box);

  final Box<String> _box;

  @override
  String? get(String key) => _box.get(key);

  @override
  Iterable<String> get keys => _box.keys.whereType<String>();

  @override
  Future<void> put(String key, String value) => _box.put(key, value);

  @override
  Future<void> delete(String key) => _box.delete(key);
}

class InMemoryBackupMetaStorage implements BackupMetaStorage {
  final _entries = <String, String>{};

  @override
  String? get(String key) => _entries[key];

  @override
  Iterable<String> get keys => _entries.keys.toList();

  @override
  Future<void> put(String key, String value) async => _entries[key] = value;

  @override
  Future<void> delete(String key) async => _entries.remove(key);
}

/// Opens [BackupMetaStore.boxName] at startup. Never throws: without the box
/// the backup runs on [InMemoryBackupMetaStorage] for the session (see
/// [backupMetaStorageFromHive]).
Future<void> openBackupMetaBox() async {
  try {
    await Hive.openBox<String>(BackupMetaStore.boxName);
  } catch (e) {
    debugPrint('[Backup] Meta box did not open: ${e.runtimeType}');
  }
}

/// The open box's storage, or memory when [openBackupMetaBox] failed or never
/// ran (tests).
BackupMetaStorage backupMetaStorageFromHive() =>
    Hive.isBoxOpen(BackupMetaStore.boxName)
        ? HiveBackupMetaStorage(Hive.box<String>(BackupMetaStore.boxName))
        : InMemoryBackupMetaStorage();

/// An account another device backed up that this one does not have, waiting
/// for the viewer to add or dismiss it. Holds no credentials: those stay in
/// the decrypted backup records and are written only when the offer is
/// accepted.
class PendingAccountOffer {
  const PendingAccountOffer({
    required this.accountId,
    required this.kind,
    required this.displayName,
    required this.fromDevice,
    required this.updatedAt,
  });

  factory PendingAccountOffer.fromJson(Map<String, dynamic> json) =>
      PendingAccountOffer(
        accountId: json['accountId'] as String,
        kind: json['kind'] as String,
        displayName: json['displayName'] as String,
        fromDevice: json['fromDevice'] as String,
        updatedAt: (json['updatedAt'] as num).toInt(),
      );

  final String accountId;

  /// A `SourceKind` name.
  final String kind;
  final String displayName;
  final String fromDevice;

  /// The backed-up record's `updatedAt`: the version a dismissal is for.
  final int updatedAt;

  Map<String, dynamic> toJson() => {
        'accountId': accountId,
        'kind': kind,
        'displayName': displayName,
        'fromDevice': fromDevice,
        'updatedAt': updatedAt,
      };

  @override
  String toString() =>
      'PendingAccountOffer($accountId, $kind, from: $fromDevice, $updatedAt)';
}

/// Local bookkeeping of the cloud backup that is not itself backed up:
/// fingerprints that keep a record's `updatedAt` stable while its value is
/// unchanged, pending account offers and dismissals, accounts whose add from
/// the backup has not finished, the `seq` of each slot
/// already merged, each slot's device name, the p2p node id to backup slot
/// id map, revoked devices still to be removed from the vault, and whether
/// the joined-by-pairing notice is pending.
class BackupMetaStore {
  BackupMetaStore(this._storage);

  static const boxName = 'backup_meta';

  static const _stampPrefix = 'stamp:';
  static const _pendingPrefix = 'pending:';
  static const _dismissedPrefix = 'dismissed:';
  static const _seqPrefix = 'seq:';
  static const _versionPrefix = 'ver:';
  static const _nodePrefix = 'node:';
  static const _claimPrefix = 'claim:';
  static const _namePrefix = 'name:';
  static const _removalPrefix = 'removal:';
  static const _unfinishedPrefix = 'unfinished:';

  final BackupMetaStorage _storage;

  /// The `updatedAt` of record [key]: the stored one while [fingerprint] is
  /// what was stored, else [nowMs], which is stored with it.
  Future<int> stamp(String key, String fingerprint, int nowMs) async {
    final current = _readStamp(key);
    if (current != null && current.fp == fingerprint) return current.at;
    await setStamp(key, fingerprint, nowMs);
    return nowMs;
  }

  /// Records [fingerprint] at [updatedAt] for [key], as after a restore that
  /// wrote another device's value.
  Future<void> setStamp(String key, String fingerprint, int updatedAt) =>
      _storage.put('$_stampPrefix$key',
          jsonEncode({'fp': fingerprint, 'at': updatedAt}));

  bool hasStamp(String key) => _readStamp(key) != null;

  /// Record keys with a stamp that start with [prefix].
  List<String> stampedKeys(String prefix) => [
        for (final k in _storage.keys)
          if (k.startsWith('$_stampPrefix$prefix'))
            k.substring(_stampPrefix.length),
      ];

  ({String fp, int at})? _readStamp(String key) {
    final raw = _storage.get('$_stampPrefix$key');
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return (fp: json['fp'] as String, at: (json['at'] as num).toInt());
    } catch (e) {
      debugPrint('[Backup] Unreadable stamp for $key: ${e.runtimeType}');
      return null;
    }
  }

  List<PendingAccountOffer> pendingAccounts() {
    final offers = <PendingAccountOffer>[];
    for (final k in _storage.keys) {
      if (!k.startsWith(_pendingPrefix)) continue;
      try {
        offers.add(PendingAccountOffer.fromJson(
            jsonDecode(_storage.get(k)!) as Map<String, dynamic>));
      } catch (e) {
        debugPrint('[Backup] Unreadable pending offer $k: ${e.runtimeType}');
      }
    }
    return offers..sort((a, b) => a.accountId.compareTo(b.accountId));
  }

  PendingAccountOffer? pendingAccount(String accountId) {
    for (final o in pendingAccounts()) {
      if (o.accountId == accountId) return o;
    }
    return null;
  }

  Future<void> putPending(PendingAccountOffer offer) => _storage.put(
      '$_pendingPrefix${offer.accountId}', jsonEncode(offer.toJson()));

  Future<void> removePending(String accountId) =>
      _storage.delete('$_pendingPrefix$accountId');

  /// Dismisses [accountId] up to version [updatedAt]; a newer version is
  /// offered again.
  Future<void> dismiss(String accountId, int updatedAt) async {
    await _storage.put('$_dismissedPrefix$accountId', '$updatedAt');
    await removePending(accountId);
  }

  /// Forgets every pending offer, dismissal and unfinished add, when this
  /// device leaves a vault: the offers came from that vault's members, and a
  /// later vault starts with nothing dismissed.
  Future<void> clearOffers() async {
    for (final k in _storage.keys.toList()) {
      if (k.startsWith(_pendingPrefix) ||
          k.startsWith(_dismissedPrefix) ||
          k.startsWith(_unfinishedPrefix)) {
        await _storage.delete(k);
      }
    }
  }

  /// Marks [accountId] as being added from the backup, at record version
  /// [updatedAt], until [finishAccount]: its record is written before its
  /// folder roots, and a failure in between must not leave it looking
  /// complete.
  Future<void> startAccount(String accountId, int updatedAt) =>
      _storage.put('$_unfinishedPrefix$accountId', '$updatedAt');

  Future<void> finishAccount(String accountId) =>
      _storage.delete('$_unfinishedPrefix$accountId');

  /// The record version an unfinished add of [accountId] was for, or null
  /// when there is none. A retry must not use an older version.
  int? unfinishedAt(String accountId) {
    final raw = _storage.get('$_unfinishedPrefix$accountId');
    return raw == null ? null : int.tryParse(raw) ?? 0;
  }

  /// Whether adding [accountId] from the backup started and did not finish.
  bool isUnfinished(String accountId) => unfinishedAt(accountId) != null;

  bool isDismissed(String accountId, int updatedAt) {
    final raw = _storage.get('$_dismissedPrefix$accountId');
    final at = raw == null ? null : int.tryParse(raw);
    return at != null && updatedAt <= at;
  }

  int mergedSeq(String slotId) =>
      int.tryParse(_storage.get('$_seqPrefix$slotId') ?? '') ?? 0;

  Future<void> setMergedSeq(String slotId, int seq) =>
      _storage.put('$_seqPrefix$slotId', '$seq');

  /// The store version of [slotId] already merged, null when none. An
  /// install that recorded int seqs ([setMergedSeq]) reads its seq as the
  /// version, which is how the relay names its versions, so an upgrade
  /// does not merge every slot again.
  String? mergedVersion(String slotId) =>
      _storage.get('$_versionPrefix$slotId') ??
      _storage.get('$_seqPrefix$slotId');

  Future<void> setMergedVersion(String slotId, String version) =>
      _storage.put('$_versionPrefix$slotId', version);

  /// Forgets every merged seq and version, when this device leaves a vault:
  /// slot ids derive from signers, so a later vault holding the same devices
  /// starts their seqs at 1 again.
  Future<void> clearMergedSeqs() async {
    for (final k in _storage.keys.toList()) {
      if (k.startsWith(_seqPrefix) || k.startsWith(_versionPrefix)) {
        await _storage.delete(k);
      }
    }
  }

  /// What this device itself recorded: its own node and the devices it
  /// added to the vault at pairing. Uploaded in its group record.
  Map<String, String> nodeToSlot() => {
        for (final k in _storage.keys)
          if (k.startsWith(_nodePrefix))
            k.substring(_nodePrefix.length): _storage.get(k)!,
      };

  Future<void> setNodeToSlot(String nodeId, String slotId) =>
      _storage.put('$_nodePrefix$nodeId', slotId);

  Future<void> removeNode(String nodeId) =>
      _storage.delete('$_nodePrefix$nodeId');

  /// The p2p node ids each slot's owner says are its own, by slot id: read
  /// from that slot's group record and nowhere else, so no member can
  /// claim a node for another member's slot.
  Map<String, Set<String>> slotClaims() => {
        for (final k in _storage.keys)
          if (k.startsWith(_claimPrefix))
            k.substring(_claimPrefix.length): {
              for (final n in _storage.get(k)!.split(','))
                if (n.isNotEmpty) n,
            },
      };

  /// Replaces [slotId]'s claim with [nodeIds] (its latest upload wins).
  Future<void> setSlotClaim(String slotId, Set<String> nodeIds) =>
      nodeIds.isEmpty
          ? _storage.delete('$_claimPrefix$slotId')
          : _storage.put(
              '$_claimPrefix$slotId', (nodeIds.toList()..sort()).join(','));

  /// Forgets every claim, when this device leaves a vault.
  Future<void> clearSlotClaims() async {
    for (final k in _storage.keys.toList()) {
      if (k.startsWith(_claimPrefix)) await _storage.delete(k);
    }
  }

  /// The device name each slot last uploaded under, by slot id, for the
  /// member list: a poll after a restart reads only the slots that changed.
  Map<String, String> slotNames() => {
        for (final k in _storage.keys)
          if (k.startsWith(_namePrefix))
            k.substring(_namePrefix.length): _storage.get(k)!,
      };

  Future<void> setSlotName(String slotId, String name) =>
      _storage.put('$_namePrefix$slotId', name);

  /// Forgets every slot name, when this device leaves a vault.
  Future<void> clearSlotNames() async {
    for (final k in _storage.keys.toList()) {
      if (k.startsWith(_namePrefix)) await _storage.delete(k);
    }
  }

  /// Devices revoked from the p2p group that may still read the backup, by
  /// p2p node id: the slot they were matched to (null until a trusted
  /// node to slot record names exactly one) and the name they had in the
  /// group, if known.
  Map<String, ({String? slotId, String? deviceName})> pendingRemovals() {
    final out = <String, ({String? slotId, String? deviceName})>{};
    for (final k in _storage.keys) {
      if (!k.startsWith(_removalPrefix)) continue;
      try {
        final json = jsonDecode(_storage.get(k)!) as Map<String, dynamic>;
        out[k.substring(_removalPrefix.length)] = (
          slotId: json['slot'] as String?,
          deviceName: json['name'] as String?,
        );
      } catch (e) {
        debugPrint('[Backup] Unreadable pending removal $k: ${e.runtimeType}');
      }
    }
    return out;
  }

  Future<void> setPendingRemoval(String nodeId,
          {String? slotId, String? deviceName}) =>
      _storage.put('$_removalPrefix$nodeId',
          jsonEncode({'slot': slotId, 'name': deviceName}));

  Future<void> removePendingRemoval(String nodeId) =>
      _storage.delete('$_removalPrefix$nodeId');

  /// Forgets every pending removal, when this device leaves a vault.
  Future<void> clearPendingRemovals() async {
    for (final k in _storage.keys.toList()) {
      if (k.startsWith(_removalPrefix)) await _storage.delete(k);
    }
  }

  /// Whether the "now backed up with your group" notice is still to be
  /// seen: set when pairing joined this device to a vault, so it survives a
  /// restart before the viewer saw it.
  bool get joinedNoticePending => _storage.get(_joinedNoticeKey) == '1';

  Future<void> setJoinedNoticePending(bool pending) => pending
      ? _storage.put(_joinedNoticeKey, '1')
      : _storage.delete(_joinedNoticeKey);

  static const _joinedNoticeKey = 'notice:joined';

  /// The listing cursor of the cloud store [kind] (a `CloudStoreKind`
  /// name), null when none is kept.
  String? cloudCursor(String kind) => _storage.get('$_cloudCursorPrefix$kind');

  Future<void> setCloudCursor(String kind, String? cursor) => cursor == null
      ? _storage.delete('$_cloudCursorPrefix$kind')
      : _storage.put('$_cloudCursorPrefix$kind', cursor);

  static const _cloudCursorPrefix = 'cloudCursor:';

  /// The Drive file id of this device's own slot, null when not created yet.
  String? get gdriveOwnFileId => _storage.get(_gdriveOwnFileIdKey);

  Future<void> setGdriveOwnFileId(String? id) => id == null
      ? _storage.delete(_gdriveOwnFileIdKey)
      : _storage.put(_gdriveOwnFileIdKey, id);

  static const _gdriveOwnFileIdKey = 'gdriveOwnFileId';
}
