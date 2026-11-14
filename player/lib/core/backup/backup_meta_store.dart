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
/// unchanged, pending account offers and dismissals, the `seq` of each slot
/// already merged, each slot's device name, the p2p node id to backup slot
/// id map, and whether the
/// joined-by-pairing notice is pending.
class BackupMetaStore {
  BackupMetaStore(this._storage);

  static const boxName = 'backup_meta';

  static const _stampPrefix = 'stamp:';
  static const _pendingPrefix = 'pending:';
  static const _dismissedPrefix = 'dismissed:';
  static const _seqPrefix = 'seq:';
  static const _nodePrefix = 'node:';
  static const _claimPrefix = 'claim:';
  static const _namePrefix = 'name:';

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

  bool isDismissed(String accountId, int updatedAt) {
    final raw = _storage.get('$_dismissedPrefix$accountId');
    final at = raw == null ? null : int.tryParse(raw);
    return at != null && updatedAt <= at;
  }

  int mergedSeq(String slotId) =>
      int.tryParse(_storage.get('$_seqPrefix$slotId') ?? '') ?? 0;

  Future<void> setMergedSeq(String slotId, int seq) =>
      _storage.put('$_seqPrefix$slotId', '$seq');

  /// Forgets every merged seq, when this device leaves a vault: slot ids
  /// derive from signers, so a later vault holding the same devices starts
  /// their seqs at 1 again.
  Future<void> clearMergedSeqs() async {
    for (final k in _storage.keys.toList()) {
      if (k.startsWith(_seqPrefix)) await _storage.delete(k);
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

  /// Whether the "now backed up with your group" notice is still to be
  /// seen: set when pairing joined this device to a vault, so it survives a
  /// restart before the viewer saw it.
  bool get joinedNoticePending => _storage.get(_joinedNoticeKey) == '1';

  Future<void> setJoinedNoticePending(bool pending) => pending
      ? _storage.put(_joinedNoticeKey, '1')
      : _storage.delete(_joinedNoticeKey);

  static const _joinedNoticeKey = 'notice:joined';
}
