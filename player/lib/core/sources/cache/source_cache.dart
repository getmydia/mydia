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
  HiveSourceCache._(this._box, this._maxEntries);

  static const String boxName = 'source_cache';

  /// Entries older than this are deleted when the box opens.
  static const Duration retention = Duration(days: 30);

  /// The box never holds more than this after a sweep; the oldest entries
  /// go first.
  static const int maxEntries = 2000;

  /// Returns without waiting for the sweep, which is off the startup path.
  static Future<HiveSourceCache> open() async {
    await initAppHive();
    final cache = HiveSourceCache._(
      await Hive.openBox<String>(boxName),
      maxEntries,
    );
    unawaited(cache._sweep(DateTime.now()).catchError((Object e) {
      debugPrint('[SourceCache] sweep failed: $e');
    }));
    return cache;
  }

  static Future<HiveSourceCache> fromBox(
    Box<String> box, {
    required DateTime now,
    int maxEntries = HiveSourceCache.maxEntries,
  }) async {
    final cache = HiveSourceCache._(box, maxEntries);
    await cache._sweep(now);
    return cache;
  }

  final Box<String> _box;
  final int _maxEntries;

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
    final doomed = <String>[];
    final kept = <(String, DateTime)>[];
    for (final key in _box.keys.whereType<String>()) {
      final entry = _decode(_box.get(key));
      if (entry == null || now.difference(entry.writtenAt) > retention) {
        doomed.add(key);
      } else {
        kept.add((key, entry.writtenAt));
      }
    }
    if (kept.length > _maxEntries) {
      kept.sort((a, b) => a.$2.compareTo(b.$2));
      doomed.addAll(
        kept.take(kept.length - _maxEntries).map((entry) => entry.$1),
      );
    }
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
