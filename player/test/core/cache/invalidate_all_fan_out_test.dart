import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/cache_watcher.dart';
import 'package:player/core/cache/fetch_log.dart';
import 'package:player/core/cache/query_key.dart';
import 'package:player/core/cache/source_group.dart';
import 'package:player/core/cache/watcher_registry.dart';

class _Watcher implements CacheWatcher {
  _Watcher(this.key, this.log, {this.gate});
  @override
  final QueryKey key;
  final List<String> log;
  final Completer<void>? gate;

  @override
  Future<bool> refetchAutomatically() async {
    log.add('start ${key.operationName}');
    await gate?.future;
    log.add('end ${key.operationName}');
    return true;
  }
}

void main() {
  test('cacheGroupOf takes the source prefix, or empty for a bare name', () {
    expect(cacheGroupOf(QueryKey('a:o:s/item')), 'a:o:s');
    expect(cacheGroupOf(QueryKey('HomeScreen')), '');
  });

  test('a stalled source does not delay another source', () async {
    final log = <String>[];
    final stall = Completer<void>();
    final slowKey = QueryKey('slow:o:s/item');
    final fastKey = QueryKey('fast:o:s/item');
    final registry = WatcherRegistry()
      ..register(slowKey, _Watcher(slowKey, log, gate: stall))
      ..register(fastKey, _Watcher(fastKey, log));
    final invalidator =
        Invalidator(registry: registry, fetchLog: InMemoryFetchLog());

    final done = invalidator.invalidateAll();
    await pumpEventQueue();
    expect(log, contains('end fast:o:s/item'));
    expect(log, isNot(contains('end slow:o:s/item')));
    stall.complete();
    await done;
  });

  test('watchers of one source refetch one after another', () async {
    final log = <String>[];
    final first = Completer<void>();
    final itemKey = QueryKey('a:o:s/item');
    final browseKey = QueryKey('a:o:s/browse');
    final registry = WatcherRegistry()
      ..register(itemKey, _Watcher(itemKey, log, gate: first))
      ..register(browseKey, _Watcher(browseKey, log));
    final done = Invalidator(registry: registry, fetchLog: InMemoryFetchLog())
        .invalidateAll();
    await pumpEventQueue();
    expect(log, ['start a:o:s/item']);
    first.complete();
    await done;
    expect(log, [
      'start a:o:s/item',
      'end a:o:s/item',
      'start a:o:s/browse',
      'end a:o:s/browse',
    ]);
  });
}
