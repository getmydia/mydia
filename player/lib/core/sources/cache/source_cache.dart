/// The last answer each source watcher received, as JSON.
///
/// The fetch log says whether an answer is fresh; this only holds it. A
/// watcher shows an entry only while the fetch log still has a time for its
/// key, so invalidating a key (which clears its fetch-log entry) makes the
/// next mount cold without touching this store.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import '../../graphql/watch/query_key.dart';
import '../../storage/app_hive.dart';

@immutable
class CacheEntry {
  const CacheEntry({required this.json, required this.writtenAt});

  final Object? json;
  final DateTime writtenAt;
}

abstract class SourceCache {
  /// Bump whenever a model's `toJson` changes shape. Older entries then read
  /// as absent instead of failing to decode.
  static const int schemaVersion = 1;

  /// Synchronous: a watcher reads it before its first fetch.
  CacheEntry? read(QueryKey key);

  Future<void> write(QueryKey key, Object? json, DateTime at);

  Future<void> delete(QueryKey key);

  /// Every entry of every source of [accountId]. Source ids are
  /// `account:profile:server` and keys start with the source id, so the
  /// prefix is `accountId:`.
  Future<void> deleteAccount(String accountId);
}

class InMemorySourceCache implements SourceCache {
  final Map<String, CacheEntry> _entries = {};

  @override
  CacheEntry? read(QueryKey key) => _entries[key.canonical];

  @override
  Future<void> write(QueryKey key, Object? json, DateTime at) async {
    _entries[key.canonical] = CacheEntry(json: json, writtenAt: at);
  }

  @override
  Future<void> delete(QueryKey key) async {
    _entries.remove(key.canonical);
  }

  @override
  Future<void> deleteAccount(String accountId) async {
    _entries.removeWhere((key, _) => key.startsWith('$accountId:'));
  }
}

/// One string per key: `{"v": schemaVersion, "at": millis, "d": json}`. A
/// string box needs no type adapter.
class HiveSourceCache implements SourceCache {
  HiveSourceCache._(this._box);

  static const String boxName = 'source_cache';

  /// Entries older than this are deleted when the box opens.
  static const Duration retention = Duration(days: 30);

  static Future<HiveSourceCache> open() async {
    await initAppHive();
    return fromBox(await Hive.openBox<String>(boxName), now: DateTime.now());
  }

  static Future<HiveSourceCache> fromBox(
    Box<String> box, {
    required DateTime now,
  }) async {
    final cache = HiveSourceCache._(box);
    await cache._sweep(now);
    return cache;
  }

  final Box<String> _box;

  @override
  CacheEntry? read(QueryKey key) => _decode(_box.get(key.canonical));

  @override
  Future<void> write(QueryKey key, Object? json, DateTime at) => _box.put(
        key.canonical,
        jsonEncode({
          'v': SourceCache.schemaVersion,
          'at': at.millisecondsSinceEpoch,
          'd': json,
        }),
      );

  @override
  Future<void> delete(QueryKey key) => _box.delete(key.canonical);

  @override
  Future<void> deleteAccount(String accountId) => _box.deleteAll(_box.keys
      .whereType<String>()
      .where((key) => key.startsWith('$accountId:'))
      .toList());

  Future<void> _sweep(DateTime now) async {
    final doomed = [
      for (final key in _box.keys.whereType<String>())
        if (_decode(_box.get(key)) case final entry
            when entry == null || now.difference(entry.writtenAt) > retention)
          key,
    ];
    if (doomed.isEmpty) return;
    try {
      await _box.deleteAll(doomed);
    } catch (e) {
      debugPrint('[SourceCache] sweep failed: $e');
    }
  }

  static CacheEntry? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, Object?>;
      if (map['v'] != SourceCache.schemaVersion) return null;
      return CacheEntry(
        json: map['d'],
        writtenAt:
            DateTime.fromMillisecondsSinceEpoch(map['at']! as int, isUtc: true),
      );
    } catch (_) {
      return null;
    }
  }
}

/// In-memory by default so tests need no setup; `main()` overrides it with
/// [HiveSourceCache].
final Provider<SourceCache> sourceCacheProvider =
    Provider<SourceCache>((ref) => InMemorySourceCache());
