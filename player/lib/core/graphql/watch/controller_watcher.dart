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
  Map<String, dynamic> variables = const {},
  required T Function(Map<String, dynamic> data) parse,
  Duration maxAge = kFreshnessThreshold,
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
    variables: variables,
    parse: parse,
    maxAge: maxAge,
    onFreshness: (value) => freshness.publish(key, value),
  );

  registry.register(key, watcher);
  ref.onDispose(() {
    registry.unregister(key, watcher);
    watcher.close();

    // Riverpod forbids touching another provider's state synchronously from
    // inside a dispose callback ("Cannot use Ref or modify other providers
    // inside life-cycles/selectors"), so the freshness clear is deferred to
    // a microtask, after the callback stack that trips that check unwinds.
    // If the whole container is being torn down at once (e.g. app shutdown,
    // test teardown), freshnessRegistryProvider may itself already be gone
    // by the time this runs; that failure is expected and safe to ignore,
    // since nothing is left to observe the cleared entry anyway.
    Future.microtask(() {
      try {
        freshness.clear(key);
      } catch (_) {
        // Provider tree already torn down.
      }
    });
  });

  return watcher;
}
