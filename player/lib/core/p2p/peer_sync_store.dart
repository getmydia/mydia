import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:hive_ce/hive.dart';

import '../playback/playback_progress_store.dart';
import '../player/progress_service.dart';
import '../sources/files/files_ids.dart';
import '../sources/files/index/index_records.dart';
import 'peer_sync_records.dart';

abstract class PeerSyncStore {
  static const boxName = 'peer_sync';

  // Roster
  Map<String, PeerMember> members();
  PeerMember? member(String nodeId);
  Future<bool> putMember(PeerMember member);

  /// Merges [incoming] roster entries. [senderNodeId] is the peer that sent
  /// them: it can never lift its own revocation (see [rosterCandidateWins]).
  Future<Set<String>> mergeRoster(
    Iterable<PeerMember> incoming, {
    required int nowMs,
    String? senderNodeId,
  });
  Future<void> clearRoster();

  // Watch & progress
  PeerWatchRecord? watchRecord(String key);
  Map<String, PeerWatchRecord> allWatchRecords();
  Future<PeerWatchRecord> setWatched(
    String key,
    bool watched, {
    required int nowMs,
  });
  Future<PeerWatchRecord> removeFromContinueWatching(
    String key, {
    required int nowMs,
  });
  Future<PeerWatchRecord> recordProgress(
    String key, {
    required int positionSeconds,
    required int durationSeconds,
    required double watchedFraction,
    required int nowMs,
  });

  // Pins
  PeerPinRecord? pinRecord({required bool isShow, required String groupKey});
  Map<String, PeerPinRecord> allPinRecords();
  Future<PeerPinRecord> setPin({
    required String groupKey,
    required bool isShow,
    required int? tmdbId,
    required bool pinned,
    required int nowMs,
  });

  // Wire delta & LWW merge
  List<PeerWatchRecord> watchRecordsSince(int landedAtExclusive);
  List<PeerPinRecord> pinRecordsSince(int landedAtExclusive);
  Future<({Set<String> changedWatchKeys, Set<String> changedPinKeys})>
      mergeRemote({
    required Iterable<WireWatchRecord> watchRecords,
    required Iterable<WirePinRecord> pinRecords,
    required int nowMs,
  });

  // Per-peer sync watermarks
  PeerWatermark? watermark(String nodeId);
  Future<void> setWatermark(String nodeId, PeerWatermark mark);

  // Initial seeding
  bool get isSeeded;
  Future<void> markSeeded();
}

/// Whether [candidate] replaces [existing] in the roster.
///
/// Last write wins on `updatedAt`, and a revocation wins a tie. A revoked
/// member is brought back only by a newer record, and never one the member
/// sends about itself ([senderNodeId]): the host that enrolls a device again
/// stamps a newer, unrevoked record, and the rest of the group accepts it on
/// the strength of the sender being someone else. Without that rule a revoked
/// device could un-revoke itself with a record of its own.
bool rosterCandidateWins(
  PeerMember? existing,
  PeerMember candidate, {
  String? senderNodeId,
}) {
  if (existing == null) return true;
  if (existing.revoked && !candidate.revoked) {
    if (senderNodeId != null &&
        senderNodeId.toLowerCase() == candidate.nodeId.toLowerCase()) {
      return false;
    }
    return candidate.updatedAt > existing.updatedAt;
  }
  if (candidate.updatedAt > existing.updatedAt) return true;
  return candidate.updatedAt == existing.updatedAt &&
      candidate.revoked &&
      !existing.revoked;
}

/// Whether [wire], with its clamped time [updatedAt], replaces [local].
/// Equal times are settled the same way on every device: watched beats
/// unwatched, then the later position, then the longer duration.
bool watchIncomingWins(
  PeerWatchRecord? local,
  WireWatchRecord wire,
  int updatedAt,
) {
  if (local == null || updatedAt > local.updatedAt) return true;
  if (updatedAt < local.updatedAt) return false;
  if (wire.watched != local.watched) return wire.watched;
  final incomingPos = wire.positionSeconds?.toInt() ?? -1;
  final localPos = local.positionSeconds ?? -1;
  if (incomingPos != localPos) return incomingPos > localPos;
  final incomingDur = wire.durationSeconds?.toInt() ?? -1;
  final localDur = local.durationSeconds ?? -1;
  return incomingDur > localDur;
}

/// Whether [wire], with its clamped time [updatedAt], replaces [local]. Equal
/// times are settled the same way on every device: pinned beats unpinned,
/// then the larger TMDB id.
bool pinIncomingWins(PeerPinRecord? local, WirePinRecord wire, int updatedAt) {
  if (local == null || updatedAt > local.updatedAt) return true;
  if (updatedAt < local.updatedAt) return false;
  if (wire.pinned != local.pinned) return wire.pinned;
  return (wire.tmdbId?.toInt() ?? -1) > (local.tmdbId ?? -1);
}

class HivePeerSyncStore implements PeerSyncStore {
  HivePeerSyncStore(this._box) {
    var maxLanded = 0;
    final meta = _box.get(_metaLastLandedAtKey);
    if (meta != null && meta['value'] is num) {
      maxLanded = (meta['value'] as num).toInt();
    }
    for (final key in _box.keys) {
      final keyStr = key.toString();
      if (keyStr.startsWith(_watchPrefix) || keyStr.startsWith(_pinPrefix)) {
        final raw = _box.get(key);
        if (raw != null && raw['landedAt'] is num) {
          final l = (raw['landedAt'] as num).toInt();
          if (l > maxLanded) maxLanded = l;
        }
      }
    }
    _lastIssuedLandedAt = maxLanded;
  }

  static const _memberPrefix = 'member:';
  static const _watchPrefix = 'watch:';
  static const _pinPrefix = 'pin:';
  static const _watermarkPrefix = 'watermark:';
  static const _metaSeededKey = 'meta:seeded';
  static const _metaLastLandedAtKey = 'meta:last_landed_at';

  final Box<Map<dynamic, dynamic>> _box;
  int _lastIssuedLandedAt = 0;

  int _nextLandedAt(int nowMs) {
    final next = max(nowMs, _lastIssuedLandedAt + 1);
    _lastIssuedLandedAt = next;
    return next;
  }

  // Roster

  @override
  Map<String, PeerMember> members() {
    final result = <String, PeerMember>{};
    for (final key in _box.keys) {
      final keyStr = key.toString();
      if (keyStr.startsWith(_memberPrefix)) {
        final nodeId = keyStr.substring(_memberPrefix.length);
        final raw = _box.get(key);
        if (raw != null) {
          try {
            result[nodeId] = PeerMember.fromMap(raw);
          } catch (e) {
            debugPrint('[HivePeerSyncStore] Corrupt member $key: $e');
          }
        }
      }
    }
    return result;
  }

  @override
  PeerMember? member(String nodeId) {
    final raw = _box.get('$_memberPrefix$nodeId');
    if (raw == null) return null;
    try {
      return PeerMember.fromMap(raw);
    } catch (e) {
      debugPrint('[HivePeerSyncStore] Corrupt member $nodeId: $e');
      return null;
    }
  }

  @override
  Future<bool> putMember(PeerMember member) async {
    final existing = this.member(member.nodeId);
    if (!rosterCandidateWins(existing, member)) return false;
    await _box.put('$_memberPrefix${member.nodeId}', member.toMap());
    return true;
  }

  @override
  Future<Set<String>> mergeRoster(
    Iterable<PeerMember> incoming, {
    required int nowMs,
    String? senderNodeId,
  }) async {
    final changed = <String>{};
    for (final m in incoming) {
      final effectiveUpdatedAt = min(m.updatedAt, nowMs + 60000);
      final candidate = m.updatedAt != effectiveUpdatedAt
          ? m.copyWith(updatedAt: effectiveUpdatedAt)
          : m;
      final existing = member(candidate.nodeId);
      final wins = rosterCandidateWins(
        existing,
        candidate,
        senderNodeId: senderNodeId,
      );

      if (wins) {
        if (existing != candidate) {
          await _box.put(
            '$_memberPrefix${candidate.nodeId}',
            candidate.toMap(),
          );
          changed.add(candidate.nodeId);
        }
      }
    }
    return changed;
  }

  @override
  Future<void> clearRoster() async {
    final memberKeys = [
      for (final key in _box.keys)
        if (key.toString().startsWith(_memberPrefix)) key,
    ];
    await _box.deleteAll(memberKeys);
  }

  // Watch & progress

  @override
  PeerWatchRecord? watchRecord(String key) {
    final raw = _box.get('$_watchPrefix$key');
    if (raw == null) return null;
    try {
      return PeerWatchRecord.fromMap(raw);
    } catch (e) {
      debugPrint('[HivePeerSyncStore] Corrupt watch record $key: $e');
      return null;
    }
  }

  @override
  Map<String, PeerWatchRecord> allWatchRecords() {
    final result = <String, PeerWatchRecord>{};
    for (final key in _box.keys) {
      final keyStr = key.toString();
      if (keyStr.startsWith(_watchPrefix)) {
        final syncKey = keyStr.substring(_watchPrefix.length);
        final raw = _box.get(key);
        if (raw != null) {
          try {
            result[syncKey] = PeerWatchRecord.fromMap(raw);
          } catch (e) {
            debugPrint('[HivePeerSyncStore] Corrupt watch record $key: $e');
          }
        }
      }
    }
    return result;
  }

  @override
  Future<PeerWatchRecord> setWatched(
    String key,
    bool watched, {
    required int nowMs,
  }) async {
    final landed = _nextLandedAt(nowMs);
    final record = PeerWatchRecord(
      key: key,
      watched: watched,
      positionSeconds: null,
      durationSeconds: null,
      updatedAt: nowMs,
      landedAt: landed,
    );
    await _box.put('$_watchPrefix$key', record.toMap());
    return record;
  }

  @override
  Future<PeerWatchRecord> removeFromContinueWatching(
    String key, {
    required int nowMs,
  }) async {
    final current = watchRecord(key);
    final landed = _nextLandedAt(nowMs);
    final record = PeerWatchRecord(
      key: key,
      watched: current?.watched ?? false,
      positionSeconds: null,
      durationSeconds: null,
      updatedAt: nowMs,
      landedAt: landed,
    );
    await _box.put('$_watchPrefix$key', record.toMap());
    return record;
  }

  @override
  Future<PeerWatchRecord> recordProgress(
    String key, {
    required int positionSeconds,
    required int durationSeconds,
    required double watchedFraction,
    required int nowMs,
  }) async {
    final current = watchRecord(key);
    if (current != null && current.updatedAt > nowMs) {
      return current;
    }
    final isWatched = (current?.watched ?? false) ||
        (durationSeconds > 0 &&
            (positionSeconds / durationSeconds) >= watchedFraction);
    final landed = _nextLandedAt(nowMs);
    final record = PeerWatchRecord(
      key: key,
      watched: isWatched,
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
      updatedAt: nowMs,
      landedAt: landed,
    );
    await _box.put('$_watchPrefix$key', record.toMap());
    return record;
  }

  // Pins

  @override
  PeerPinRecord? pinRecord({required bool isShow, required String groupKey}) {
    final key = pinSyncKey(isShow: isShow, groupKey: groupKey);
    final raw = _box.get('$_pinPrefix$key');
    if (raw == null) return null;
    try {
      return PeerPinRecord.fromMap(raw);
    } catch (e) {
      debugPrint('[HivePeerSyncStore] Corrupt pin record $key: $e');
      return null;
    }
  }

  @override
  Map<String, PeerPinRecord> allPinRecords() {
    final result = <String, PeerPinRecord>{};
    for (final key in _box.keys) {
      final keyStr = key.toString();
      if (keyStr.startsWith(_pinPrefix)) {
        final pinKey = keyStr.substring(_pinPrefix.length);
        final raw = _box.get(key);
        if (raw != null) {
          try {
            result[pinKey] = PeerPinRecord.fromMap(raw);
          } catch (e) {
            debugPrint('[HivePeerSyncStore] Corrupt pin record $key: $e');
          }
        }
      }
    }
    return result;
  }

  @override
  Future<PeerPinRecord> setPin({
    required String groupKey,
    required bool isShow,
    required int? tmdbId,
    required bool pinned,
    required int nowMs,
  }) async {
    final key = pinSyncKey(isShow: isShow, groupKey: groupKey);
    final landed = _nextLandedAt(nowMs);
    final record = PeerPinRecord(
      key: key,
      groupKey: groupKey,
      isShow: isShow,
      tmdbId: tmdbId,
      pinned: pinned,
      updatedAt: nowMs,
      landedAt: landed,
    );
    await _box.put('$_pinPrefix$key', record.toMap());
    return record;
  }

  // Wire delta & LWW merge

  @override
  List<PeerWatchRecord> watchRecordsSince(int landedAtExclusive) {
    final list = allWatchRecords()
        .values
        .where((r) => r.landedAt > landedAtExclusive)
        .toList()
      ..sort((a, b) => a.landedAt.compareTo(b.landedAt));
    return list;
  }

  @override
  List<PeerPinRecord> pinRecordsSince(int landedAtExclusive) {
    final list = allPinRecords()
        .values
        .where((r) => r.landedAt > landedAtExclusive)
        .toList()
      ..sort((a, b) => a.landedAt.compareTo(b.landedAt));
    return list;
  }

  @override
  Future<({Set<String> changedWatchKeys, Set<String> changedPinKeys})>
      mergeRemote({
    required Iterable<WireWatchRecord> watchRecords,
    required Iterable<WirePinRecord> pinRecords,
    required int nowMs,
  }) async {
    final changedWatch = <String>{};
    final changedPin = <String>{};

    for (final wire in watchRecords) {
      final effectiveUpdatedAt = min(wire.updatedAtMs.toInt(), nowMs + 60000);
      final local = watchRecord(wire.key);
      final incomingWins = watchIncomingWins(local, wire, effectiveUpdatedAt);

      if (incomingWins) {
        final landed = _nextLandedAt(nowMs);
        final record = PeerWatchRecord(
          key: wire.key,
          watched: wire.watched,
          positionSeconds: wire.positionSeconds?.toInt(),
          durationSeconds: wire.durationSeconds?.toInt(),
          updatedAt: effectiveUpdatedAt,
          landedAt: landed,
        );
        await _box.put('$_watchPrefix${wire.key}', record.toMap());
        changedWatch.add(wire.key);
      }
    }

    for (final wire in pinRecords) {
      final effectiveUpdatedAt = min(wire.updatedAtMs.toInt(), nowMs + 60000);
      final local = pinRecord(isShow: wire.isShow, groupKey: wire.groupKey);
      final incomingWins = pinIncomingWins(local, wire, effectiveUpdatedAt);

      if (incomingWins) {
        final landed = _nextLandedAt(nowMs);
        final record = PeerPinRecord(
          key: wire.key,
          groupKey: wire.groupKey,
          isShow: wire.isShow,
          tmdbId: wire.tmdbId?.toInt(),
          pinned: wire.pinned,
          updatedAt: effectiveUpdatedAt,
          landedAt: landed,
        );
        await _box.put('$_pinPrefix${wire.key}', record.toMap());
        changedPin.add(wire.key);
      }
    }

    return (changedWatchKeys: changedWatch, changedPinKeys: changedPin);
  }

  // Per-peer sync watermarks

  @override
  PeerWatermark? watermark(String nodeId) {
    final raw = _box.get('$_watermarkPrefix$nodeId');
    if (raw == null) return null;
    try {
      return PeerWatermark.fromMap(raw);
    } catch (e) {
      debugPrint('[HivePeerSyncStore] Corrupt watermark $nodeId: $e');
      return null;
    }
  }

  @override
  Future<void> setWatermark(String nodeId, PeerWatermark mark) async {
    await _box.put('$_watermarkPrefix$nodeId', mark.toMap());
  }

  // Initial seeding

  @override
  bool get isSeeded {
    final raw = _box.get(_metaSeededKey);
    return raw != null && raw['seeded'] == true;
  }

  @override
  Future<void> markSeeded() async {
    await _box.put(_metaSeededKey, {'seeded': true});
  }
}

class InMemoryPeerSyncStore implements PeerSyncStore {
  final Map<String, PeerMember> _members = {};
  final Map<String, PeerWatchRecord> _watchRecords = {};
  final Map<String, PeerPinRecord> _pinRecords = {};
  final Map<String, PeerWatermark> _watermarks = {};
  bool _seeded = false;
  int _lastIssuedLandedAt = 0;

  int _nextLandedAt(int nowMs) {
    final next = max(nowMs, _lastIssuedLandedAt + 1);
    _lastIssuedLandedAt = next;
    return next;
  }

  // Roster

  @override
  Map<String, PeerMember> members() => Map.unmodifiable(_members);

  @override
  PeerMember? member(String nodeId) => _members[nodeId];

  @override
  Future<bool> putMember(PeerMember member) async {
    final existing = _members[member.nodeId];
    if (!rosterCandidateWins(existing, member)) return false;
    _members[member.nodeId] = member;
    return true;
  }

  @override
  Future<Set<String>> mergeRoster(
    Iterable<PeerMember> incoming, {
    required int nowMs,
    String? senderNodeId,
  }) async {
    final changed = <String>{};
    for (final m in incoming) {
      final effectiveUpdatedAt = min(m.updatedAt, nowMs + 60000);
      final candidate = m.updatedAt != effectiveUpdatedAt
          ? m.copyWith(updatedAt: effectiveUpdatedAt)
          : m;
      final existing = _members[candidate.nodeId];
      final wins = rosterCandidateWins(
        existing,
        candidate,
        senderNodeId: senderNodeId,
      );

      if (wins) {
        if (existing != candidate) {
          _members[candidate.nodeId] = candidate;
          changed.add(candidate.nodeId);
        }
      }
    }
    return changed;
  }

  @override
  Future<void> clearRoster() async {
    _members.clear();
  }

  // Watch & progress

  @override
  PeerWatchRecord? watchRecord(String key) => _watchRecords[key];

  @override
  Map<String, PeerWatchRecord> allWatchRecords() =>
      Map.unmodifiable(_watchRecords);

  @override
  Future<PeerWatchRecord> setWatched(
    String key,
    bool watched, {
    required int nowMs,
  }) async {
    final landed = _nextLandedAt(nowMs);
    final record = PeerWatchRecord(
      key: key,
      watched: watched,
      positionSeconds: null,
      durationSeconds: null,
      updatedAt: nowMs,
      landedAt: landed,
    );
    _watchRecords[key] = record;
    return record;
  }

  @override
  Future<PeerWatchRecord> removeFromContinueWatching(
    String key, {
    required int nowMs,
  }) async {
    final current = _watchRecords[key];
    final landed = _nextLandedAt(nowMs);
    final record = PeerWatchRecord(
      key: key,
      watched: current?.watched ?? false,
      positionSeconds: null,
      durationSeconds: null,
      updatedAt: nowMs,
      landedAt: landed,
    );
    _watchRecords[key] = record;
    return record;
  }

  @override
  Future<PeerWatchRecord> recordProgress(
    String key, {
    required int positionSeconds,
    required int durationSeconds,
    required double watchedFraction,
    required int nowMs,
  }) async {
    final current = _watchRecords[key];
    if (current != null && current.updatedAt > nowMs) {
      return current;
    }
    final isWatched = (current?.watched ?? false) ||
        (durationSeconds > 0 &&
            (positionSeconds / durationSeconds) >= watchedFraction);
    final landed = _nextLandedAt(nowMs);
    final record = PeerWatchRecord(
      key: key,
      watched: isWatched,
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
      updatedAt: nowMs,
      landedAt: landed,
    );
    _watchRecords[key] = record;
    return record;
  }

  // Pins

  @override
  PeerPinRecord? pinRecord({required bool isShow, required String groupKey}) {
    final key = pinSyncKey(isShow: isShow, groupKey: groupKey);
    return _pinRecords[key];
  }

  @override
  Map<String, PeerPinRecord> allPinRecords() => Map.unmodifiable(_pinRecords);

  @override
  Future<PeerPinRecord> setPin({
    required String groupKey,
    required bool isShow,
    required int? tmdbId,
    required bool pinned,
    required int nowMs,
  }) async {
    final key = pinSyncKey(isShow: isShow, groupKey: groupKey);
    final landed = _nextLandedAt(nowMs);
    final record = PeerPinRecord(
      key: key,
      groupKey: groupKey,
      isShow: isShow,
      tmdbId: tmdbId,
      pinned: pinned,
      updatedAt: nowMs,
      landedAt: landed,
    );
    _pinRecords[key] = record;
    return record;
  }

  // Wire delta & LWW merge

  @override
  List<PeerWatchRecord> watchRecordsSince(int landedAtExclusive) {
    final list = _watchRecords.values
        .where((r) => r.landedAt > landedAtExclusive)
        .toList()
      ..sort((a, b) => a.landedAt.compareTo(b.landedAt));
    return list;
  }

  @override
  List<PeerPinRecord> pinRecordsSince(int landedAtExclusive) {
    final list = _pinRecords.values
        .where((r) => r.landedAt > landedAtExclusive)
        .toList()
      ..sort((a, b) => a.landedAt.compareTo(b.landedAt));
    return list;
  }

  @override
  Future<({Set<String> changedWatchKeys, Set<String> changedPinKeys})>
      mergeRemote({
    required Iterable<WireWatchRecord> watchRecords,
    required Iterable<WirePinRecord> pinRecords,
    required int nowMs,
  }) async {
    final changedWatch = <String>{};
    final changedPin = <String>{};

    for (final wire in watchRecords) {
      final effectiveUpdatedAt = min(wire.updatedAtMs.toInt(), nowMs + 60000);
      final local = _watchRecords[wire.key];
      final incomingWins = watchIncomingWins(local, wire, effectiveUpdatedAt);

      if (incomingWins) {
        final landed = _nextLandedAt(nowMs);
        final record = PeerWatchRecord(
          key: wire.key,
          watched: wire.watched,
          positionSeconds: wire.positionSeconds?.toInt(),
          durationSeconds: wire.durationSeconds?.toInt(),
          updatedAt: effectiveUpdatedAt,
          landedAt: landed,
        );
        _watchRecords[wire.key] = record;
        changedWatch.add(wire.key);
      }
    }

    for (final wire in pinRecords) {
      final effectiveUpdatedAt = min(wire.updatedAtMs.toInt(), nowMs + 60000);
      final local = _pinRecords[wire.key];
      final incomingWins = pinIncomingWins(local, wire, effectiveUpdatedAt);

      if (incomingWins) {
        final landed = _nextLandedAt(nowMs);
        final record = PeerPinRecord(
          key: wire.key,
          groupKey: wire.groupKey,
          isShow: wire.isShow,
          tmdbId: wire.tmdbId?.toInt(),
          pinned: wire.pinned,
          updatedAt: effectiveUpdatedAt,
          landedAt: landed,
        );
        _pinRecords[wire.key] = record;
        changedPin.add(wire.key);
      }
    }

    return (changedWatchKeys: changedWatch, changedPinKeys: changedPin);
  }

  // Per-peer sync watermarks

  @override
  PeerWatermark? watermark(String nodeId) => _watermarks[nodeId];

  @override
  Future<void> setWatermark(String nodeId, PeerWatermark mark) async {
    _watermarks[nodeId] = mark;
  }

  // Initial seeding

  @override
  bool get isSeeded => _seeded;

  @override
  Future<void> markSeeded() async {
    _seeded = true;
  }
}

/// Seeds [syncStore] from [indexBox] and [progressStore] on first run.
/// No-op if [syncStore.isSeeded] is true.
Future<void> seedPeerSyncStoreIfNeeded({
  required PeerSyncStore syncStore,
  required Box<Map<dynamic, dynamic>> indexBox,
  required PlaybackProgressStore progressStore,
  int? nowMs,
}) async {
  if (syncStore.isSeeded) return;
  final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;

  // 1. Playback progress from progressStore
  for (final p in progressStore.all()) {
    final parsed = parseFilesId(p.mediaId);
    if (parsed == null || parsed.isProvisional) continue;
    final accountId =
        p.sourceId.contains(':') ? p.sourceId.split(':').first : p.sourceId;
    final isEpisode = p.mediaType == 'episode' ||
        (parsed.season != null && parsed.episode != null);
    final syncKey = syncKeyForFilesItem(
      accountId: accountId,
      externalId: p.mediaId,
      isEpisode: isEpisode,
    );
    if (syncKey != null) {
      await syncStore.recordProgress(
        syncKey,
        positionSeconds: p.positionSeconds,
        durationSeconds: p.durationSeconds,
        watchedFraction: ProgressService.watchedThreshold,
        nowMs: p.updatedAt.millisecondsSinceEpoch,
      );
    }
  }

  // 2. Watched state and pins from indexBox (nowMs wins over older progress)
  for (final key in indexBox.keys) {
    if (key is! String) continue;
    final slash1 = key.indexOf('/');
    if (slash1 < 0) continue;
    final accountId = key.substring(0, slash1);
    final rest = key.substring(slash1 + 1);
    final slash2 = rest.indexOf('/');
    if (slash2 < 0) continue;
    final type = rest.substring(0, slash2);
    final id = rest.substring(slash2 + 1);

    if (type == 'watched') {
      final parsed = parseFilesId(id);
      if (parsed == null || parsed.isProvisional) continue;
      final isEpisode = parsed.season != null && parsed.episode != null;
      final syncKey = syncKeyForFilesItem(
        accountId: accountId,
        externalId: id,
        isEpisode: isEpisode,
      );
      if (syncKey != null) {
        await syncStore.setWatched(syncKey, true, nowMs: now);
      }
    } else if (type == 'group') {
      final raw = indexBox.get(key);
      if (raw != null) {
        try {
          final gm = GroupMatch.fromMap(raw);
          if (gm.pinned) {
            await syncStore.setPin(
              groupKey: gm.groupKey,
              isShow: gm.isShow,
              tmdbId: gm.tmdbId,
              pinned: true,
              nowMs: gm.matchedAt.millisecondsSinceEpoch,
            );
          }
        } catch (e) {
          debugPrint(
              '[seedPeerSyncStoreIfNeeded] Failed to parse group $key: $e');
        }
      }
    }
  }

  await syncStore.markSeeded();
}
