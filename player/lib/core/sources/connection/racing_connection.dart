/// Reaches one server over whichever of its known connections answers,
/// starting with the first to answer and moving to a better one when it
/// answers too. Plex feeds it plex.tv's advertised connections; Jellyfin
/// its entered URL and its LAN address.
///
/// Modelled on the relay-first, hot-swap idea Mydia's own connection uses:
/// browsing starts after one round trip, usually through the relay or the
/// WAN address, and moves to the LAN address in place. A swap only changes
/// the base the next request reads; a stream already playing keeps the URL
/// it opened with.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../domain/sources/source_error.dart';
import '../media_source.dart';
import '../source.dart';
import 'source_connection.dart';

/// Returns the server id the server at [base] reports, or null.
typedef IdentityProbe = Future<String?> Function(Uri base, Duration timeout);

/// The server's current connections, as its source knows them.
typedef CandidateFetch = Future<List<ServerConnection>> Function();

/// [all] filtered to what may be tried and sorted best first.
typedef ConnectionRanking = List<ServerConnection> Function(
    List<ServerConnection> all);

/// Lower is better: local, then remote, then relay; HTTPS before HTTP.
int connectionRank(ServerConnection c) =>
    (c.relay ? 4 : (c.local ? 0 : 2)) + (c.uri.scheme == 'https' ? 0 : 1);

class RacingConnection implements SourceConnection {
  RacingConnection({
    required this.expectedId,
    required List<ServerConnection> candidates,
    required IdentityProbe probe,
    required ConnectionRanking rank,
    CandidateFetch? refetch,
    this.refreshEvery = const Duration(minutes: 15),
  })  : _candidates = candidates,
        _probe = probe,
        _rank = rank,
        _refetch = refetch;

  /// Started by the first use, not the constructor: the switcher builds a
  /// source just to show its status, and an idle source must not leave a
  /// timer running (widget tests fail on one).
  void _ensureTimer() {
    if (_disposed) return;
    _timer ??= Timer.periodic(refreshEvery, (_) => unawaited(refresh()));
  }

  static const _directTimeout = Duration(seconds: 3);
  static const _relayTimeout = Duration(seconds: 6);

  /// The id the server must report back: Plex's `machineIdentifier`,
  /// Jellyfin's server `Id`.
  final String expectedId;
  final ConnectionRanking _rank;

  /// Each candidate's place in the latest ranking, by URI. A candidate
  /// missing from it (the list changed under a race) sorts last.
  Map<Uri, int> _order = const {};
  int _orderOf(ServerConnection c) => _order[c.uri] ?? 1 << 20;

  final Duration refreshEvery;
  final IdentityProbe _probe;
  final CandidateFetch? _refetch;
  List<ServerConnection> _candidates;

  final _status = ValueNotifier(SourceConnectionStatus.connecting);
  final _waiters = <Completer<Uri>>[];
  Timer? _timer;
  ServerConnection? _current;
  int _generation = 0;
  bool _racing = false;
  bool _disposed = false;

  @override
  ValueListenable<SourceConnectionStatus> get status => _status;

  @override
  Uri? get currentBase => _current?.uri;

  @override
  Future<Uri> base() {
    if (_disposed) return Future.error(const SourceException.unreachable());
    _ensureTimer();
    final current = _current;
    if (current != null) return Future.value(current.uri);
    final waiter = Completer<Uri>();
    _waiters.add(waiter);
    if (!_racing) unawaited(_race());
    return waiter.future;
  }

  @override
  Future<void> refresh() async {
    if (_disposed) return;
    _ensureTimer();
    final refetch = _refetch;
    if (refetch != null) {
      try {
        final fresh = await refetch();
        if (_disposed) return;
        if (fresh.isNotEmpty) _candidates = fresh;
      } catch (e) {
        debugPrint('[RacingConnection] Could not re-fetch connections: $e');
      }
    }
    await _race();
  }

  @override
  void reportFailure(Uri base) {
    if (_disposed || _current?.uri != base) return;
    _current = null;
    _status.value = SourceConnectionStatus.connecting;
    unawaited(_race());
  }

  Future<void> _race() async {
    if (_disposed) return;
    final generation = ++_generation;
    _racing = true;
    final answered = <ServerConnection>[];
    final ranked = _rank(_candidates);
    _order = {for (var i = 0; i < ranked.length; i++) ranked[i].uri: i};
    if (_current == null) _status.value = SourceConnectionStatus.connecting;

    await Future.wait([
      for (final candidate in ranked)
        _probeOne(candidate, generation, answered),
    ]);
    if (generation != _generation || _disposed) return;
    _racing = false;

    final current = _current;
    if (current != null && answered.any((c) => c.uri == current.uri)) return;
    if (answered.isEmpty) {
      _current = null;
      _status.value = SourceConnectionStatus.unreachable;
      final waiters = List.of(_waiters);
      _waiters.clear();
      for (final w in waiters) {
        w.completeError(const SourceException.unreachable());
      }
      return;
    }
    answered.sort((a, b) => _orderOf(a).compareTo(_orderOf(b)));
    _adopt(answered.first);
  }

  Future<void> _probeOne(
    ServerConnection candidate,
    int generation,
    List<ServerConnection> answered,
  ) async {
    final timeout = candidate.relay ? _relayTimeout : _directTimeout;
    String? id;
    try {
      id = await _probe(candidate.uri, timeout).timeout(timeout);
    } catch (_) {
      id = null;
    }
    if (generation != _generation || _disposed) return;
    if (id != expectedId) return;
    answered.add(candidate);
    final current = _current;
    if (current == null || _orderOf(candidate) < _orderOf(current)) {
      _adopt(candidate);
    }
  }

  void _adopt(ServerConnection connection) {
    _current = connection;
    _status.value = connection.relay
        ? SourceConnectionStatus.relay
        : connection.local
            ? SourceConnectionStatus.local
            : SourceConnectionStatus.remote;
    final waiters = List.of(_waiters);
    _waiters.clear();
    for (final w in waiters) {
      w.complete(connection.uri);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    final waiters = List.of(_waiters);
    _waiters.clear();
    for (final w in waiters) {
      w.completeError(const SourceException.unreachable());
    }
    _status.dispose();
  }
}
