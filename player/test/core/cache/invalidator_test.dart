import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/cache_watcher.dart';
import 'package:player/core/cache/fetch_log.dart';
import 'package:player/core/cache/invalidation_target.dart';
import 'package:player/core/cache/query_key.dart';
import 'package:player/core/cache/watcher_registry.dart';

import '../../test_utils/query_keys.dart';

/// A [CacheWatcher] that counts the automatic refetches it is asked for.
///
/// A real watcher restamps its fetch-log entry when its refetch lands, so
/// this one does too, which is what lets the tests tell "cleared then
/// restamped" from "cleared and left cold".
class _FakeWatcher implements CacheWatcher {
  _FakeWatcher(this.key, this._log, {this.canRefetch});

  @override
  final QueryKey key;
  final FetchLog _log;

  /// Mirrors a watcher's decline guard; throwing simulates a broken guard.
  final bool Function()? canRefetch;

  int refetches = 0;

  @override
  Future<bool> refetchAutomatically() async {
    final allowed = canRefetch == null || canRefetch!();
    if (!allowed) return false;
    refetches++;
    await _log.record(key, DateTime(2026, 8, 1));
    return true;
  }
}

/// A [FetchLog] that reports when `clearAll()` runs, delegating everything
/// else to [_inner]. Pins the ordering contract of `invalidateAll`: the log
/// is cleared before any live watcher is refetched.
class _CallOrderFetchLog implements FetchLog {
  _CallOrderFetchLog(this._inner, {required void Function() onClearAll})
      : _onClearAll = onClearAll;

  final FetchLog _inner;
  final void Function() _onClearAll;

  @override
  DateTime? lastFetchedAt(QueryKey key) => _inner.lastFetchedAt(key);

  @override
  Future<void> record(QueryKey key, DateTime when) => _inner.record(key, when);

  @override
  Future<void> clear(QueryKey key) => _inner.clear(key);

  @override
  Future<void> clearFamily(String operationName) =>
      _inner.clearFamily(operationName);

  @override
  Future<void> clearAll() async {
    _onClearAll();
    await _inner.clearAll();
  }
}

/// A [FetchLog] that reports when `clearFamily()` runs, delegating everything
/// else to [_inner]. Same technique as [_CallOrderFetchLog], for a family
/// target.
class _FamilyClearOrderFetchLog implements FetchLog {
  _FamilyClearOrderFetchLog(this._inner,
      {required void Function() onClearFamily})
      : _onClearFamily = onClearFamily;

  final FetchLog _inner;
  final void Function() _onClearFamily;

  @override
  DateTime? lastFetchedAt(QueryKey key) => _inner.lastFetchedAt(key);

  @override
  Future<void> record(QueryKey key, DateTime when) => _inner.record(key, when);

  @override
  Future<void> clear(QueryKey key) => _inner.clear(key);

  @override
  Future<void> clearFamily(String operationName) {
    _onClearFamily();
    return _inner.clearFamily(operationName);
  }

  @override
  Future<void> clearAll() => _inner.clearAll();
}

/// A [FetchLog] whose `clear` throws for one designated key and records
/// every key it was actually asked to clear (successes only) — used to prove
/// that one failing key in a batch does not block its siblings.
class _PartiallyFailingFetchLog implements FetchLog {
  _PartiallyFailingFetchLog(this._failingKey);

  final QueryKey _failingKey;
  final List<QueryKey> clearedKeys = [];

  @override
  DateTime? lastFetchedAt(QueryKey key) => null;

  @override
  Future<void> record(QueryKey key, DateTime when) async {}

  @override
  Future<void> clear(QueryKey key) async {
    if (key == _failingKey) {
      throw StateError('simulated storage failure clearing $key');
    }
    clearedKeys.add(key);
  }

  @override
  Future<void> clearFamily(String operationName) async {}

  @override
  Future<void> clearAll() async {}
}

/// A [FetchLog] whose `clearAll` always throws — used to prove that a
/// transient storage failure on the resume path degrades to "live watchers
/// still refetch" rather than aborting the whole batch before it starts.
class _ClearAllFailingFetchLog implements FetchLog {
  @override
  DateTime? lastFetchedAt(QueryKey key) => null;

  @override
  Future<void> record(QueryKey key, DateTime when) async {}

  @override
  Future<void> clear(QueryKey key) async {}

  @override
  Future<void> clearFamily(String operationName) async {}

  @override
  Future<void> clearAll() async {
    throw StateError('simulated storage failure clearing the fetch log');
  }
}

/// A [FetchLog] whose `clearFamily` always throws — used to prove that a
/// transient storage failure degrades to "live screens still refresh" rather
/// than skipping the refetches for that target entirely.
class _FamilyClearFailingFetchLog implements FetchLog {
  final Map<QueryKey, DateTime> _entries = {};

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
  Future<void> clearAll() async {
    _entries.clear();
  }

  @override
  Future<void> clearFamily(String operationName) async {
    throw StateError('simulated storage failure clearing $operationName');
  }
}

void main() {
  group('Invalidator', () {
    test('a live watcher is refetched', () async {
      final log = InMemoryFetchLog();
      final watcher = _FakeWatcher(QueryKeys.home, log);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await invalidator.invalidate([QueryKeys.home.target]);

      expect(watcher.refetches, 1);
      expect(log.lastFetchedAt(QueryKeys.home), isNotNull);
    });

    test(
        'a live watcher that allows automatic refetch (canRefetch true or '
        'unset) still refetches', () async {
      final log = InMemoryFetchLog();
      final watcher = _FakeWatcher(QueryKeys.home, log, canRefetch: () => true);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await invalidator.invalidate([QueryKeys.home.target]);

      expect(watcher.refetches, 1);
      expect(log.lastFetchedAt(QueryKeys.home), isNotNull);
    });

    test(
        'a live watcher that declines automatic refetch (e.g. a paginated '
        'library) has its fetch-log entry cleared instead of being '
        'refetched', () async {
      // Simulates a library scrolled past page 1 catching an automatic
      // invalidation (a favorite toggle, an app-resume sweep): refetching
      // would re-issue the original page-1 variables and silently collapse
      // the accumulated pages, so the watcher must decline and the
      // invalidator must fall back to clearing the log entry instead, so the
      // screen is treated as cold on its next fresh mount rather than
      // staying silently stale forever.
      final log = InMemoryFetchLog({QueryKeys.home: DateTime(2026, 7, 28)});
      final watcher =
          _FakeWatcher(QueryKeys.home, log, canRefetch: () => false);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await invalidator.invalidate([QueryKeys.home.target]);

      expect(
        watcher.refetches,
        0,
        reason: 'a declining watcher must not be refetched automatically',
      );
      expect(log.lastFetchedAt(QueryKeys.home), isNull);
    });

    test('a dormant key has its fetch-log entry cleared instead', () async {
      final log = InMemoryFetchLog({
        QueryKeys.unwatched: DateTime(2026, 7, 28),
      });
      final invalidator =
          Invalidator(registry: WatcherRegistry(), fetchLog: log);

      await invalidator.invalidate([QueryKeys.unwatched.target]);

      expect(log.lastFetchedAt(QueryKeys.unwatched), isNull);
    });

    test('invalidateAll clears the log and refetches every live watcher',
        () async {
      final log = InMemoryFetchLog({
        QueryKeys.unwatched: DateTime(2026, 7, 28),
      });
      final watcher = _FakeWatcher(QueryKeys.home, log);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await invalidator.invalidateAll();

      expect(log.lastFetchedAt(QueryKeys.unwatched), isNull);
      expect(watcher.refetches, 1);
      // The live watcher's refetch restamps its own entry after clearAll()
      // wipes it, so it survives to the end of the call.
      expect(log.lastFetchedAt(QueryKeys.home), isNotNull);
    });

    test(
        'invalidateAll clears the log before refetching any live watcher '
        '(ordering)', () async {
      // The restamp assertion above does not pin the clear-then-refetch
      // order on its own, so snapshot the refetch count at the moment
      // clearAll() runs.
      final log = InMemoryFetchLog({
        QueryKeys.unwatched: DateTime(2026, 7, 28),
      });
      late final _FakeWatcher watcher;
      int? refetchesAtClear;
      final orderTrackingLog = _CallOrderFetchLog(
        log,
        onClearAll: () => refetchesAtClear = watcher.refetches,
      );
      watcher = _FakeWatcher(QueryKeys.home, orderTrackingLog);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator =
          Invalidator(registry: registry, fetchLog: orderTrackingLog);

      await invalidator.invalidateAll();

      expect(refetchesAtClear, 0,
          reason: 'clearAll() must run before any live watcher is '
              'refetched, not after');
      expect(watcher.refetches, 1);
    });

    test(
        'a key whose fetch-log clear throws does not block the rest of the '
        'batch', () async {
      final log = _PartiallyFailingFetchLog(QueryKeys.favorites);
      final invalidator =
          Invalidator(registry: WatcherRegistry(), fetchLog: log);

      await invalidator.invalidate([
        QueryKeys.favorites.target,
        QueryKeys.home.target,
        QueryKeys.tvShowsList.target,
      ]);

      expect(log.clearedKeys, [QueryKeys.home, QueryKeys.tvShowsList]);
    });

    test(
        'invalidateAll still refetches live watchers when clearing the '
        'fetch log throws', () async {
      final log = _ClearAllFailingFetchLog();
      final watcher = _FakeWatcher(QueryKeys.home, log);

      final registry = WatcherRegistry()..register(QueryKeys.home, watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      // Must not throw: a failed clearAll() must not abort before a single
      // watcher gets a chance to refetch.
      await invalidator.invalidateAll();

      expect(watcher.refetches, 1);
    });

    test('a family target refetches every live watcher of that operation',
        () async {
      final log = InMemoryFetchLog();
      final one = _FakeWatcher(QueryKeys.collectionItems('c1'), log);
      final two = _FakeWatcher(QueryKeys.collectionItems('c2'), log);

      final registry = WatcherRegistry()
        ..register(QueryKeys.collectionItems('c1'), one)
        ..register(QueryKeys.collectionItems('c2'), two);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await invalidator.invalidate([Families.collectionItems]);

      expect(one.refetches, 1);
      expect(two.refetches, 1);
    });

    test('a dormant family member has its fetch-log entry cleared', () async {
      final log = InMemoryFetchLog({
        QueryKeys.collectionItems('c1'): DateTime(2026, 7, 28),
        QueryKeys.home: DateTime(2026, 7, 28),
      });
      final invalidator =
          Invalidator(registry: WatcherRegistry(), fetchLog: log);

      await invalidator.invalidate([Families.collectionItems]);

      expect(log.lastFetchedAt(QueryKeys.collectionItems('c1')), isNull);
      expect(log.lastFetchedAt(QueryKeys.home), isNotNull);
    });

    test('a live family member keeps the record its refetch just wrote',
        () async {
      // Snapshot the refetch count at the moment `clearFamily()` runs, so
      // the clear-before-refetch order is pinned, then check the refetch
      // restamped the record: clearing first must not leave a screen that
      // refreshed a moment ago cold on its next mount.
      final innerLog = InMemoryFetchLog();
      late final _FakeWatcher watcher;
      int? refetchesAtClear;
      final orderTrackingLog = _FamilyClearOrderFetchLog(
        innerLog,
        onClearFamily: () => refetchesAtClear = watcher.refetches,
      );
      watcher = _FakeWatcher(QueryKeys.collectionItems('c1'), orderTrackingLog);

      final registry = WatcherRegistry()
        ..register(QueryKeys.collectionItems('c1'), watcher);
      final invalidator =
          Invalidator(registry: registry, fetchLog: orderTrackingLog);

      await invalidator.invalidate([Families.collectionItems]);

      expect(refetchesAtClear, 0,
          reason: 'clearFamily() must run before any live family member is '
              'refetched, not after');
      expect(watcher.refetches, 1);
      expect(
        orderTrackingLog.lastFetchedAt(QueryKeys.collectionItems('c1')),
        isNotNull,
      );
    });

    test(
        'a family target does not touch another operation with the same prefix',
        () async {
      final log = InMemoryFetchLog({
        QueryKeys.collectionItems('c1'): DateTime(2026, 7, 28),
        QueryKeys.collections: DateTime(2026, 7, 28),
      });
      final invalidator =
          Invalidator(registry: WatcherRegistry(), fetchLog: log);

      await invalidator.invalidate([const FamilyTarget('Collection')]);

      expect(log.lastFetchedAt(QueryKeys.collectionItems('c1')), isNotNull);
      expect(log.lastFetchedAt(QueryKeys.collections), isNotNull);
    });

    test('a family clear that throws still refetches the live watchers',
        () async {
      final log = _FamilyClearFailingFetchLog();
      final watcher = _FakeWatcher(QueryKeys.collectionItems('c1'), log);

      final registry = WatcherRegistry()
        ..register(QueryKeys.collectionItems('c1'), watcher);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await invalidator.invalidate([Families.collectionItems]);

      expect(watcher.refetches, 1);
    });

    test(
        'a watcher whose refetch throws does not block the rest of the '
        'family', () async {
      // Registration order controls iteration order here: `WatcherRegistry`
      // stores watchers in a plain `Map` (a `LinkedHashMap`, which iterates
      // in insertion order). Registering the throwing watcher first means it
      // is the one `_invalidateFamily`'s loop reaches first, so this test
      // actually exercises the failure mode an unisolated loop hits: a
      // throwing watcher processed *second* would let the healthy one
      // succeed regardless of isolation, proving nothing.
      final log = InMemoryFetchLog();
      final throwing = _FakeWatcher(
        QueryKeys.collectionItems('c1'),
        log,
        canRefetch: () => throw StateError('simulated refetch failure'),
      );
      final healthy = _FakeWatcher(QueryKeys.collectionItems('c2'), log);

      final registry = WatcherRegistry()
        ..register(QueryKeys.collectionItems('c1'), throwing)
        ..register(QueryKeys.collectionItems('c2'), healthy);
      final invalidator = Invalidator(registry: registry, fetchLog: log);

      await invalidator.invalidate([Families.collectionItems]);

      expect(healthy.refetches, 1);
    });

    test('unregister only removes the watcher it was given', () async {
      final log = InMemoryFetchLog();
      final first = _FakeWatcher(QueryKeys.home, log);
      final second = _FakeWatcher(QueryKeys.home, log);

      final registry = WatcherRegistry()..register(QueryKeys.home, second);
      registry.unregister(QueryKeys.home, first);

      expect(registry.find(QueryKeys.home), same(second));
    });

    test('the providers wire the registry and log together', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(invalidatorProvider), isA<Invalidator>());
      expect(container.read(watcherRegistryProvider), isA<WatcherRegistry>());
    });
  });

  group('WatcherRegistry.family', () {
    test('returns every live watcher for the operation', () {
      final log = InMemoryFetchLog();
      final one = _FakeWatcher(QueryKeys.collectionItems('c1'), log);
      final two = _FakeWatcher(QueryKeys.collectionItems('c2'), log);
      final other = _FakeWatcher(QueryKeys.home, log);

      final registry = WatcherRegistry()
        ..register(QueryKeys.collectionItems('c1'), one)
        ..register(QueryKeys.collectionItems('c2'), two)
        ..register(QueryKeys.home, other);

      expect(registry.family('CollectionItems'), hasLength(2));
      expect(registry.family('CollectionItems'), containsAll([one, two]));
    });

    test('an operation name that prefixes another does not match it', () {
      final log = InMemoryFetchLog();
      final watcher = _FakeWatcher(QueryKeys.collectionItems('c1'), log);

      final registry = WatcherRegistry()
        ..register(QueryKeys.collectionItems('c1'), watcher);

      expect(registry.family('Collection'), isEmpty);
      expect(registry.family('Collections'), isEmpty);
    });

    test('an operation with no live watcher returns empty', () {
      expect(WatcherRegistry().family('CollectionItems'), isEmpty);
    });
  });
}
