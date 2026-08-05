import 'package:flutter_riverpod/flutter_riverpod.dart';

// `gql` is a transitive dependency reached through graphql_flutter (via
// graphql -> gql_exec/gql_link). It is not exported by graphql_flutter, so
// DocumentNode needs a direct import; the same pattern is already used
// throughout lib/graphql/*.graphql.dart.
// ignore: depend_on_referenced_packages
import 'package:gql/ast.dart' show DocumentNode;

import '../graphql_provider.dart';
import 'fetch_log.dart';
import 'freshness.dart';
import 'query_key.dart';
import 'query_watcher.dart';
import 'watcher_registry.dart';

/// Builds a [QueryWatcher] wired to a Riverpod notifier: registered for
/// invalidation, publishing freshness, and torn down with the provider.
///
/// Call this from a `StreamNotifier.build()` and return `watcher.stream`.
QueryWatcher<T> createWatcher<T>(
  Ref ref, {
  required QueryKey key,
  required DocumentNode document,
  DocumentNode? fallbackDocument,
  Map<String, dynamic> variables = const {},
  required T Function(Map<String, dynamic> data) parse,
  Duration maxAge = kFreshnessThreshold,
  bool Function()? canRefetch,
}) {
  final registry = ref.read(watcherRegistryProvider);
  final freshness = ref.read(freshnessRegistryProvider.notifier);

  final watcher = QueryWatcher<T>(
    key: key,
    // Watched, not read: a connection-mode or auth change rebuilds the
    // notifier and therefore the watcher, against the new client.
    client: ref.watch(asyncGraphqlClientProvider.future),
    fetchLog: ref.read(fetchLogProvider),
    document: document,
    fallbackDocument: fallbackDocument,
    variables: variables,
    parse: parse,
    maxAge: maxAge,
    onFreshness: (value) => freshness.publish(key, value),
    canRefetch: canRefetch,
  );

  registry.register(key, watcher);
  ref.onDispose(() {
    registry.unregister(key, watcher);
    watcher.close();

    // Riverpod's debug build asserts against touching another provider's
    // state synchronously from inside a dispose callback ("Cannot use Ref
    // or modify other providers inside life-cycles/selectors"; release
    // builds don't hit this — the assert only fires under kDebugMode), so
    // the freshness clear is deferred to a microtask, after the callback
    // stack that trips that check unwinds. `FreshnessRegistry.clear` itself
    // guards against an unmounted ref, for the case where the whole
    // container was torn down at once and freshnessRegistryProvider is
    // already gone by the time this runs.
    Future.microtask(() {
      // A successor watcher may have already taken over this key by the
      // time this runs — this closure only knows about the watcher it was
      // built for, not whether it's still the live one. Consulting the
      // registry (key-only, unlike `unregister`'s identity check) before
      // clearing avoids wiping out a live successor's freshly published
      // freshness entry.
      if (registry.find(key) != null) return;
      freshness.clear(key);
    });
  });

  return watcher;
}
