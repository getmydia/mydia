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
import 'schema_downgrade.dart';

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
    this.fallbackDocument,
    this.variables = const {},
    required this.parse,
    this.maxAge = kFreshnessThreshold,
    this.onFreshness,
    this.canRefetch,
    DateTime Function() clock = DateTime.now,
  })  : _clientFuture = client,
        _clock = clock {
    _started = _start();
  }

  final QueryKey key;
  final FetchLog fetchLog;
  final DocumentNode document;

  /// Document to retry with once, if the server rejects [document] for
  /// selecting a field it does not define. Null means no fallback: a rejection
  /// surfaces as a stream error like any other.
  final DocumentNode? fallbackDocument;

  /// Set once a downgrade has happened, so a server that rejects both
  /// documents cannot loop.
  bool _downgraded = false;

  final Map<String, dynamic> variables;
  final T Function(Map<String, dynamic> data) parse;
  final Duration maxAge;
  final void Function(Freshness freshness)? onFreshness;

  /// Guards *automatic* refetches only (see [refetchAutomatically]): returns
  /// false when the caller has local state a page-1 refetch would corrupt
  /// (e.g. a paginated list). Null means "always allowed". Never consulted
  /// by [refetch] itself, so a user-initiated refresh always runs.
  final bool Function()? canRefetch;

  final Future<GraphQLClient> _clientFuture;
  final DateTime Function() _clock;

  /// Owned deliberately: an `async*` generator forwarding the observable's
  /// stream would terminate on the first error, permanently closing the pipe.
  final StreamController<T> _controller = StreamController<T>.broadcast();

  ObservableQuery<Map<String, dynamic>>? _query;
  StreamSubscription<QueryResult<Map<String, dynamic>>>? _subscription;
  Future<void>? _started;
  bool _closed = false;

  /// True from the moment `_start()` picks `cacheAndNetwork` until the first
  /// non-cache-sourced result of *that* start lands (network success,
  /// network failure, or anything else). A warm-cache `cacheAndNetwork`
  /// start emits exactly two results, `source: cache` then `source: network`,
  /// and neither is `QueryResultSource.loading`, so `result.isLoading` alone
  /// never signals the background half of that fetch. This flag lets
  /// `_onResult` treat that first cache emission as refreshing.
  ///
  /// Scoped tightly on purpose: cleared for good on the first non-cache
  /// result so later cache-sourced rebroadcasts (a `fetchMore()` rewrite, or
  /// an unrelated cache write touching the same normalized entities) never
  /// re-arm it, and so a network failure clears it too rather than leaving
  /// the tier-1 line spinning forever.
  bool _awaitingInitialNetworkResult = false;

  Stream<T> get stream => _controller.stream;

  /// The document currently in play: [document] until a schema downgrade has
  /// happened, [fallbackDocument] (or [document] again, if there is none)
  /// after. [document] itself is final, so `_start()` reads through here
  /// instead.
  DocumentNode get _activeDocument =>
      _downgraded ? (fallbackDocument ?? document) : document;

  Future<void> _start() async {
    try {
      final client = await _clientFuture;
      if (_closed) return;

      final probe = WatchQueryOptions<Map<String, dynamic>>(
        document: _activeDocument,
        variables: variables,
      );

      final fetchPolicy = selectFetchPolicy(
        lastFetchedAt: fetchLog.lastFetchedAt(key),
        cacheHasData: _cacheHasData(client, probe.asRequest),
        maxAge: maxAge,
        now: _clock(),
      );
      // Set before subscribing: the first result can in principle arrive as
      // soon as `watchQuery` is called, so the flag must already be correct
      // by the time `_onResult` first runs.
      _awaitingInitialNetworkResult =
          fetchPolicy == FetchPolicy.cacheAndNetwork;

      final options = WatchQueryOptions<Map<String, dynamic>>(
        document: _activeDocument,
        variables: variables,
        fetchPolicy: fetchPolicy,
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

  /// Tears down the current observable and starts a new one against
  /// [_activeDocument]. Only reached after a schema downgrade.
  Future<void> _restart() async {
    await _subscription?.cancel();
    _subscription = null;
    // ObservableQuery.close returns FutureOr<QueryLifecycle>, matching how
    // close() below tears the same objects down.
    await _query?.close();
    _query = null;

    if (_closed) return;
    _started = _start();
    await _started;
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

    // This result counts as the pending cache half of a warm-cache
    // `cacheAndNetwork` start only while `_awaitingInitialNetworkResult` is
    // still armed *and* it is itself cache-sourced. Any non-cache result
    // (the network leg landing, in success or failure; or a stream-level
    // anomaly) disarms the flag for good, so later cache-sourced
    // rebroadcasts of this same watcher never re-trigger it.
    final awaitingInitialNetworkResult = _awaitingInitialNetworkResult &&
        result.source == QueryResultSource.cache;
    if (result.source != QueryResultSource.cache) {
      _awaitingInitialNetworkResult = false;
    }

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
        awaitingNetworkResult: awaitingInitialNetworkResult,
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
      final exception = result.exception!;

      if (!_downgraded &&
          fallbackDocument != null &&
          isUnknownFieldError(exception)) {
        _downgraded = true;
        unawaited(_restart());
        return;
      }

      _addError(exception, StackTrace.current);
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

  /// Refetches on the network unconditionally. Always honored, even for a
  /// paginated screen: this is the user-initiated path (pull-to-refresh,
  /// changing sort) and has always meant "go back to page 1". [canRefetch]
  /// only gates [refetchAutomatically], never this method.
  ///
  /// A no-op only while the *initial* fetch is still in flight:
  /// `ObservableQuery.isRefetchSafe` is false during `QueryLifecycle.pending`
  /// and `ObservableQuery.refetch()` throws when it is not refetch-safe, so
  /// this guard exists to stop a double pull-to-refresh from surfacing an
  /// exception during the first load. It does **not** guard against a second
  /// `refetch()` racing an already-in-flight *refetch*: once the initial
  /// fetch completes, the lifecycle becomes (and stays) `completed`, and
  /// `isRefetchSafe` stays true from then on, so a second `refetch()` called
  /// while an earlier refetch is still outstanding does issue a second
  /// network request. That is harmless rather than a bug to fix:
  /// `ObservableQuery.addResult` drops any result older than the one it has
  /// already applied, so the two requests can only ever resolve to whichever
  /// completes later.
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

  /// Refetches for *automatic* invalidation only: a mutation elsewhere in
  /// the app, or an app-resume sweep. Never called for a user-initiated
  /// action; use [refetch] for that.
  ///
  /// Declines, returning `false`, when [canRefetch] is supplied and returns
  /// false right now (e.g. a library screen scrolled past page 1, where an
  /// automatic page-1 refetch would silently collapse it). Callers such as
  /// `Invalidator` must treat a `false` return as "this key was not
  /// refreshed" and fall back accordingly, so the screen does not stay
  /// silently stale forever.
  Future<bool> refetchAutomatically() async {
    final allowed = canRefetch == null || canRefetch!();
    if (!allowed) return false;
    await refetch();
    return true;
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
