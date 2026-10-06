import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

/// Servers this device redials when their connection drops.
///
/// One entry per Mydia instance in use. Each keeps its own attempt budget
/// and timer, so one server dropping cannot spend another's
/// retries, and dialing one never stops the other being watched. Peers that
/// are not watched, such as another player connecting for remote control,
/// are ignored.
class WatchedPeers {
  WatchedPeers({
    required String? Function(String peer) nodeIdFor,
    required bool Function(String nodeId) isConnected,
    required Future<void> Function(String endpointAddrJson) dial,
    int maxAttempts = 3,
    Duration delay = const Duration(seconds: 2),
  })  : _nodeIdFor = nodeIdFor,
        _isConnected = isConnected,
        _dial = dial,
        _maxAttempts = maxAttempts,
        _delay = delay;

  final String? Function(String peer) _nodeIdFor;
  final bool Function(String nodeId) _isConnected;
  final Future<void> Function(String endpointAddrJson) _dial;
  final int _maxAttempts;
  final Duration _delay;

  final Map<String, _WatchedPeer> _peers = {};

  /// Watch the server at [endpointAddrJson]. Watching one already watched
  /// replaces the address its redials use and keeps its budget.
  void watch(String endpointAddrJson) {
    final nodeId = _nodeIdFor(endpointAddrJson);
    if (nodeId == null) return;
    final existing = _peers[nodeId];
    if (existing != null) {
      existing.endpointAddr = endpointAddrJson;
      return;
    }
    _peers[nodeId] = _WatchedPeer(endpointAddrJson);
  }

  /// Stop watching [peer], a node id or an EndpointAddr JSON.
  void unwatch(String peer) {
    final nodeId = _nodeIdFor(peer);
    if (nodeId == null) return;
    _peers.remove(nodeId)?.timer?.cancel();
  }

  bool isWatched(String nodeId) => _peers.containsKey(nodeId);

  void resetAttempts(String nodeId) => _peers[nodeId]?.attempts = 0;

  void onConnected(String nodeId) {
    final peer = _peers[nodeId];
    if (peer == null) return;
    peer.attempts = 0;
    peer.timer?.cancel();
    peer.timer = null;
  }

  void onDisconnected(String nodeId) {
    final peer = _peers[nodeId];
    if (peer == null) return;
    _schedule(nodeId, peer);
  }

  void clear() {
    for (final peer in _peers.values) {
      peer.timer?.cancel();
    }
    _peers.clear();
  }

  void _schedule(String nodeId, _WatchedPeer peer) {
    if (peer.attempts >= _maxAttempts) {
      debugPrint('[P2P] Auto-reconnect attempts exhausted for $nodeId '
          '(${peer.attempts}/$_maxAttempts)');
      return;
    }
    peer.timer?.cancel();
    peer.attempts++;
    debugPrint('[P2P] Scheduling auto-reconnect to $nodeId, attempt '
        '${peer.attempts}/$_maxAttempts in ${_delay.inSeconds}s');

    peer.timer = Timer(_delay, () async {
      // Unwatched, or replaced by a later watch, while the timer ran.
      if (!identical(_peers[nodeId], peer)) return;
      if (_isConnected(nodeId)) return;
      try {
        await _dial(peer.endpointAddr);
      } catch (e) {
        debugPrint('[P2P] Auto-reconnect to $nodeId failed: $e');
        if (identical(_peers[nodeId], peer)) _schedule(nodeId, peer);
      }
    });
  }
}

class _WatchedPeer {
  _WatchedPeer(this.endpointAddr);

  String endpointAddr;
  int attempts = 0;
  Timer? timer;
}
