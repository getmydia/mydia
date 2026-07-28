import 'dart:async';

// `gql` is a transitive dependency reached through graphql_flutter (via
// graphql -> gql_exec/gql_link). It is not exported by graphql_flutter, so
// DocumentNode needs a direct import; the same pattern is already used
// throughout lib/graphql/*.graphql.dart.
// ignore: depend_on_referenced_packages
import 'package:gql/ast.dart' show DocumentNode;
import 'package:graphql_flutter/graphql_flutter.dart';

import 'fetch_log.dart';
import 'freshness.dart';
import 'query_key.dart';

/// The age gate: which fetch policy a watcher starts with.
///
/// `cacheAndNetwork` is safe here precisely because a listener is attached to
/// the resulting `ObservableQuery`. The same policy on a one-shot
/// `client.query()` silently discards the network result, which is the defect
/// this module exists to fix.
FetchPolicy selectFetchPolicy({
  required DateTime? lastFetchedAt,
  required bool cacheHasData,
  required Duration maxAge,
  required DateTime now,
}) {
  if (lastFetchedAt == null || !cacheHasData) {
    // No log entry means infinitely stale: cold start, shimmer, real fetch.
    return FetchPolicy.networkOnly;
  }
  return now.difference(lastFetchedAt) <= maxAge
      ? FetchPolicy.cacheAndNetwork
      : FetchPolicy.networkOnly;
}

/// Owns one `ObservableQuery`: construct, subscribe, refetch, fetchMore, close.
///
/// It exists so eleven controllers do not each hand-roll stream teardown and
/// refetch-safety guards.
class QueryWatcher<T> {
  QueryWatcher({
    required this.key,
    required Future<GraphQLClient> client,
    required this.fetchLog,
    required this.document,
    this.variables = const {},
    required this.parse,
    this.maxAge = kFreshnessThreshold,
    this.onFreshness,
    DateTime Function() clock = DateTime.now,
  })  : _clientFuture = client,
        _clock = clock {
    _started = _start();
  }

  final QueryKey key;
  final FetchLog fetchLog;
  final DocumentNode document;
  final Map<String, dynamic> variables;
  final T Function(Map<String, dynamic> data) parse;
  final Duration maxAge;
  final void Function(Freshness freshness)? onFreshness;

  final Future<GraphQLClient> _clientFuture;
  final DateTime Function() _clock;

  /// Owned deliberately: an `async*` generator forwarding the observable's
  /// stream would terminate on the first error, permanently closing the pipe.
  final StreamController<T> _controller = StreamController<T>.broadcast();

  ObservableQuery<Map<String, dynamic>>? _query;
  StreamSubscription<QueryResult<Map<String, dynamic>>>? _subscription;
  Future<void>? _started;
  bool _closed = false;

  Stream<T> get stream => _controller.stream;

  Future<void> _start() async {
    try {
      final client = await _clientFuture;
      if (_closed) return;

      final probe = WatchQueryOptions<Map<String, dynamic>>(
        document: document,
        variables: variables,
      );

      final options = WatchQueryOptions<Map<String, dynamic>>(
        document: document,
        variables: variables,
        fetchPolicy: selectFetchPolicy(
          lastFetchedAt: fetchLog.lastFetchedAt(key),
          cacheHasData: _cacheHasData(client, probe.asRequest),
          maxAge: maxAge,
          now: _clock(),
        ),
        // Library default is false, which produces a watcher that never
        // fetches anything.
        fetchResults: true,
      );

      final query = client.watchQuery(options);
      _query = query;
      _subscription = query.stream.listen(_onResult, onError: _addError);
    } catch (error, stackTrace) {
      _query = null;
      _addError(error, stackTrace);
    }
  }

  bool _cacheHasData(GraphQLClient client, Request request) {
    try {
      return client.readQuery(request, optimistic: true) != null;
    } catch (_) {
      // A partial or unreadable cache entry is not usable data.
      return false;
    }
  }

  /// The central mapping rule from a [QueryResult] onto the stream:
  ///
  /// - data present: emit it, publish freshness separately
  /// - no data plus exception: emit a stream error
  /// - no data, still loading: emit nothing, the notifier is already loading
  void _onResult(QueryResult<Map<String, dynamic>> result) {
    final now = _clock();

    // A failed network round-trip still arrives with `source: network`
    // (`QueryManager._resolveQueryOnNetwork`'s catch path builds the result
    // that way, and `carryForwardDataOnException` then attaches the
    // *previous* data). Only a result with no exception is a completed
    // fetch worth stamping; otherwise keep whatever the log already says.
    DateTime? fetchedAt;
    if (result.source == QueryResultSource.network && !result.hasException) {
      fetchedAt = now;
      unawaited(fetchLog.record(key, now));
    } else {
      fetchedAt = fetchLog.lastFetchedAt(key);
    }

    try {
      onFreshness?.call(Freshness.from(
        result: result,
        fetchedAt: fetchedAt,
        maxAge: maxAge,
        now: now,
      ));
    } catch (error, stackTrace) {
      _addError(error, stackTrace);
    }

    final data = result.data;
    if (data != null) {
      try {
        _add(parse(data));
      } catch (error, stackTrace) {
        _addError(error, stackTrace);
      }
      return;
    }

    if (result.hasException) {
      _addError(result.exception!, StackTrace.current);
    }
  }

  void _add(T value) {
    if (!_controller.isClosed) _controller.add(value);
  }

  void _addError(Object error, [StackTrace? stackTrace]) {
    if (!_controller.isClosed) {
      _controller.addError(error, stackTrace ?? StackTrace.current);
    }
  }

  /// Refetches on the network. A no-op while a fetch is already in flight:
  /// `ObservableQuery.refetch()` throws when it is not refetch-safe, and a
  /// double pull-to-refresh must not surface an exception.
  ///
  /// If the client future itself rejected, `_query` stays null forever: the
  /// captured future re-throws the same cached error on every await, so
  /// retrying `_start()` here would only push a second identical error. A
  /// watcher in that state stays dead until the provider that owns it is
  /// rebuilt against a fresh client future.
  Future<void> refetch() async {
    if (_closed) return;
    await _started;

    final query = _query;
    if (query == null || !query.isRefetchSafe) return;
    await query.refetch();
  }

  /// Fetches the next page. The library forces `FetchPolicy.noCache` on the
  /// request and writes the merged result back under the original request key,
  /// then rebroadcasts it down this same stream.
  Future<void> fetchMore(FetchMoreOptions options) async {
    if (_closed) return;
    await _started;

    final query = _query;
    if (query == null) return;
    await query.fetchMore(options);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    // ObservableQuery.close returns FutureOr<QueryLifecycle>.
    await _query?.close();
    await _controller.close();
  }
}
