/// Wires a [SourceWatcher] into Riverpod the way `createWatcher` wires a
/// `QueryWatcher`: registered for invalidation, publishing freshness, and
/// torn down with the provider.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../graphql/watch/fetch_log.dart';
import '../../graphql/watch/freshness.dart';
import '../../graphql/watch/query_key.dart';
import '../../graphql/watch/watcher_registry.dart';
import 'source_cache.dart';
import 'source_watcher.dart';

/// Call from a provider body and return `watcher.stream`. Read the source
/// with `ref.watch(mediaSourceProvider(id))` in that body, so a new
/// `MediaSource` instance rebuilds the provider and therefore the watcher.
SourceWatcher<T> createSourceWatcher<T>(
  Ref ref, {
  required QueryKey key,
  required Future<T> Function() fetch,
  required Object? Function(T value) encode,
  required T Function(Object? json) decode,
  Duration maxAge = kFreshnessThreshold,
  bool Function()? canRefetch,
}) {
  final registry = ref.read(watcherRegistryProvider);
  final freshness = ref.read(freshnessRegistryProvider.notifier);

  final watcher = SourceWatcher<T>(
    key: key,
    fetch: fetch,
    cache: ref.read(sourceCacheProvider),
    fetchLog: ref.read(fetchLogProvider),
    encode: encode,
    decode: decode,
    maxAge: maxAge,
    onFreshness: (value) => freshness.publish(key, value),
    canRefetch: canRefetch,
  );

  registry.register(key, watcher);
  ref.onDispose(() {
    registry.unregister(key, watcher);
    unawaited(watcher.close());
    // Deferred for the same reason as in `createWatcher`: Riverpod's debug
    // build rejects touching another provider from a dispose callback.
    Future.microtask(() {
      if (registry.find(key) != null) return;
      freshness.clear(key);
    });
  });

  return watcher;
}
