import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'query_key.dart';

/// When each query last reached the network.
///
/// A missing entry means "never fetched by this build", which the age gate
/// treats as infinitely stale. That is what lets existing installations repair
/// themselves on first launch after the update, with no migration step.
abstract class FetchLog {
  /// Reads synchronously: the age gate runs while a watcher is being built.
  DateTime? lastFetchedAt(QueryKey key);

  Future<void> record(QueryKey key, DateTime when);

  Future<void> clear(QueryKey key);

  /// Clears every entry for [operationName], whatever its variables.
  ///
  /// [clear] takes an exact key, which cannot reach a parameterized key whose
  /// variables the caller does not know. That gap is the whole reason
  /// `FamilyTarget` exists.
  Future<void> clearFamily(String operationName);

  Future<void> clearAll();
}

/// Non-persistent implementation. Used by tests, and as the default before
/// `main()` installs the Hive-backed one.
class InMemoryFetchLog implements FetchLog {
  InMemoryFetchLog([Map<QueryKey, DateTime> seed = const {}])
      : _entries = Map<QueryKey, DateTime>.of(seed);

  final Map<QueryKey, DateTime> _entries;

  @override
  DateTime? lastFetchedAt(QueryKey key) => _entries[key];

  @override
  Future<void> record(QueryKey key, DateTime when) async {
    _entries[key] = when;
  }

  @override
  Future<void> clear(QueryKey key) async {
    _entries.remove(key);
  }

  @override
  Future<void> clearFamily(String operationName) async {
    _entries.removeWhere((key, _) => key.operationName == operationName);
  }

  @override
  Future<void> clearAll() async {
    _entries.clear();
  }
}

/// Hive-backed implementation. Values are epoch milliseconds so the box needs
/// no type adapter.
class HiveFetchLog implements FetchLog {
  HiveFetchLog(this._box);

  static const String boxName = 'mydia_fetch_log';

  static Future<HiveFetchLog> open() async {
    await Hive.initFlutter();
    return HiveFetchLog(await Hive.openBox<int>(boxName));
  }

  final Box<int> _box;

  @override
  DateTime? lastFetchedAt(QueryKey key) {
    final millis = _box.get(key.canonical);
    if (millis == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  @override
  Future<void> record(QueryKey key, DateTime when) =>
      _box.put(key.canonical, when.millisecondsSinceEpoch);

  @override
  Future<void> clear(QueryKey key) => _box.delete(key.canonical);

  @override
  Future<void> clearFamily(String operationName) async {
    // Matched on the canonical string, which is
    // `'$operationName(${jsonEncode(sortedVariables)})'`. The trailing paren
    // is what makes the prefix unambiguous: an operation name cannot contain
    // one, so `Collection` matches neither `CollectionItems(...)` nor
    // `Collections(...)`.
    final prefix = '$operationName(';
    // Materialised before deleting: mutating the box while iterating its own
    // key view is not safe.
    final doomed = _box.keys
        .whereType<String>()
        .where((key) => key.startsWith(prefix))
        .toList();

    await _box.deleteAll(doomed);
  }

  @override
  Future<void> clearAll() async {
    await _box.clear();
  }
}

/// The app's fetch log.
///
/// Defaults to a non-persistent log so tests and widget previews work without
/// setup; `main()` overrides it with [HiveFetchLog].
final Provider<FetchLog> fetchLogProvider =
    Provider<FetchLog>((ref) => InMemoryFetchLog());
