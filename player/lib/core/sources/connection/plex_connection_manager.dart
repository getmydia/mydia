/// Reaches one Plex server over whichever of its advertised connections
/// answers, starting with the first to answer and moving to a better one
/// when it answers too.
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

/// Returns the `machineIdentifier` the server at [base] reports, or null.
typedef IdentityProbe = Future<String?> Function(Uri base, Duration timeout);

/// The server's current `connections[]` from plex.tv.
typedef CandidateFetch = Future<List<ServerConnection>> Function();

/// Lower is better: local, then remote, then relay; HTTPS before HTTP.
int plexConnectionRank(ServerConnection c) =>
    (c.relay ? 4 : (c.local ? 0 : 2)) + (c.uri.scheme == 'https' ? 0 : 1);

/// [all] in preference order, without plain HTTP except on the LAN, and
/// not even there when the server requires HTTPS.
List<ServerConnection> rankPlexConnections(
  List<ServerConnection> all, {
  required bool allowInsecureLocal,
}) =>
    all
        .where((c) =>
            c.uri.scheme == 'https' ||
            (c.local && !c.relay && allowInsecureLocal))
        .toList()
      ..sort((a, b) => plexConnectionRank(a).compareTo(plexConnectionRank(b)));

class PlexConnectionManager implements SourceConnection {
  PlexConnectionManager({
    required this.machineIdentifier,
    required List<ServerConnection> candidates,
    required IdentityProbe probe,
    CandidateFetch? refetch,
    this.allowInsecureLocal = true,
    this.refreshEvery = const Duration(minutes: 15),
  })  : _candidates = candidates,
        _probe = probe,
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

  final String machineIdentifier;
  final bool allowInsecureLocal;
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
        debugPrint('[PlexConnection] Could not re-fetch connections: $e');
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
    final ranked = rankPlexConnections(_candidates,
        allowInsecureLocal: allowInsecureLocal);
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
    answered
        .sort((a, b) => plexConnectionRank(a).compareTo(plexConnectionRank(b)));
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
    if (id != machineIdentifier) return;
    answered.add(candidate);
    final current = _current;
    if (current == null ||
        plexConnectionRank(candidate) < plexConnectionRank(current)) {
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
