import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:player/native/lib.dart';

/// Default iroh relay URL (our own relay).
/// Can be overridden at build time via dart-define IROH_RELAY_URL.
const _defaultRelayUrl = 'https://cae1-1.relay.mydia.dev';
const _customIrohRelayUrl = String.fromEnvironment('IROH_RELAY_URL');

/// Display placeholder for when using the default relay
const defaultRelayUrl = _defaultRelayUrl;

/// Provider for the P2pService
final p2pServiceProvider = Provider<P2pService>((ref) {
  final service = P2pService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Notifier for P2P status updates
class P2pStatusNotifier extends Notifier<P2pStatus> {
  StreamSubscription<P2pStatus>? _subscription;

  @override
  P2pStatus build() {
    final service = ref.watch(p2pServiceProvider);

    // Clean up on dispose
    ref.onDispose(() {
      _subscription?.cancel();
    });

    // Listen to status changes
    _subscription = service.onStatusChanged.listen((status) {
      debugPrint(
          '[P2pStatusNotifier] Received status update: peerConnectionType=${status.peerConnectionType}');
      state = status;
    });

    // Return initial state from service
    final initialStatus = service.status;
    debugPrint(
        '[P2pStatusNotifier] Initial status: peerConnectionType=${initialStatus.peerConnectionType}');
    return initialStatus;
  }

  /// Reinitialize P2P with a new relay URL.
  /// Note: This requires resetting and recreating the P2P host.
  Future<void> reinitializeWithRelayUrl(String? relayUrl) async {
    try {
      final p2pService = ref.read(p2pServiceProvider);

      // Reset old host (allows re-initialization)
      p2pService.reset();

      // Reinitialize with new relay URL
      await p2pService.initialize(relayUrl: relayUrl);

      state = p2pService.status;
    } catch (e) {
      debugPrint('[P2pStatusNotifier] Failed to reinitialize: $e');
    }
  }
}

/// Provider for P2P status that auto-updates when P2P service emits changes
final p2pStatusNotifierProvider =
    NotifierProvider<P2pStatusNotifier, P2pStatus>(P2pStatusNotifier.new);

/// Connection type for a peer (relay vs direct)
enum P2pConnectionType {
  /// Direct peer-to-peer connection
  direct,

  /// Connection via relay server
  relay,

  /// Using both relay and direct paths
  mixed,

  /// No active connection
  none,
}

/// P2P status information for UI display
class P2pStatus {
  final bool isInitialized;
  final bool isRelayConnected;
  final int connectedPeersCount;
  final String? nodeAddr;
  final String? relayUrl;
  final P2pConnectionType peerConnectionType;

  const P2pStatus({
    required this.isInitialized,
    required this.isRelayConnected,
    required this.connectedPeersCount,
    this.nodeAddr,
    this.relayUrl,
    this.peerConnectionType = P2pConnectionType.none,
  });

  const P2pStatus.initial()
      : isInitialized = false,
        isRelayConnected = false,
        connectedPeersCount = 0,
        nodeAddr = null,
        relayUrl = null,
        peerConnectionType = P2pConnectionType.none;

  P2pStatus copyWith({
    bool? isInitialized,
    bool? isRelayConnected,
    int? connectedPeersCount,
    String? nodeAddr,
    String? relayUrl,
    P2pConnectionType? peerConnectionType,
  }) {
    return P2pStatus(
      isInitialized: isInitialized ?? this.isInitialized,
      isRelayConnected: isRelayConnected ?? this.isRelayConnected,
      connectedPeersCount: connectedPeersCount ?? this.connectedPeersCount,
      nodeAddr: nodeAddr ?? this.nodeAddr,
      relayUrl: relayUrl ?? this.relayUrl,
      peerConnectionType: peerConnectionType ?? this.peerConnectionType,
    );
  }
}

/// Max auto-reconnect attempts before giving up (reset on successful connect).
const _maxAutoReconnectAttempts = 3;

/// Delay before attempting auto-reconnect after a disconnect event.
const _autoReconnectDelay = Duration(seconds: 2);

/// Service to handle P2P networking via iroh-based Rust Native Core
class P2pService {
  P2PHost? _host;
  bool _isInitialized = false;
  bool _isRelayConnected = false;
  String? _nodeAddr;
  String? _nodeId;
  final Set<String> _connectedPeers = {};

  // Cached status fields - updated from P2P events to avoid sync FFI calls
  P2pConnectionType _currentConnectionType = P2pConnectionType.none;
  String? _cachedRelayUrl;

  // Auto-reconnect state
  String? _lastDialedEndpointAddr;
  int _autoReconnectAttempts = 0;
  Timer? _autoReconnectTimer;

  // Subscription to the native host's event stream. Must be cancelled before
  // the host is dropped or the status controllers are closed: the Rust host
  // is only dropped when it is garbage collected, not synchronously on
  // dispose, so without cancelling this explicitly a torn-down host can keep
  // emitting events into an already-closed StreamController.
  StreamSubscription<String>? _eventSubscription;

  // Stream of P2P status updates
  final _statusController = StreamController<P2pStatus>.broadcast();
  Stream<P2pStatus> get onStatusChanged => _statusController.stream;

  // Stream of peer connection events
  final _peerConnectedController = StreamController<String>.broadcast();
  Stream<String> get onPeerConnected => _peerConnectedController.stream;

  /// Returns true if the P2P host is initialized
  bool get isInitialized => _isInitialized;

  /// Returns true if connected to a relay
  bool get isRelayConnected => _isRelayConnected;

  /// This node's EndpointAddr JSON (for sharing with peers)
  String? get nodeAddr => _nodeAddr;

  /// This node's ID (PublicKey string)
  String? get nodeId => _nodeId;

  /// Current P2P status (built from cached event data, no FFI calls)
  P2pStatus get status {
    final relayUrl = _getEffectiveRelayUrl();
    final peerConnectionType = _getPeerConnectionType();
    return P2pStatus(
      isInitialized: _isInitialized,
      isRelayConnected: _isRelayConnected,
      connectedPeersCount: _connectedPeers.length,
      nodeAddr: _nodeAddr,
      relayUrl: relayUrl,
      peerConnectionType: peerConnectionType,
    );
  }

  /// Get the peer connection type from cached event data (no FFI call)
  P2pConnectionType _getPeerConnectionType() {
    return _currentConnectionType;
  }

  /// Parse a connection type string from Rust events into a P2pConnectionType
  static P2pConnectionType _parseConnectionType(String connectionType) {
    return switch (connectionType) {
      'direct' => P2pConnectionType.direct,
      'relay' => P2pConnectionType.relay,
      'mixed' => P2pConnectionType.mixed,
      _ => P2pConnectionType.none,
    };
  }

  /// The custom relay URL passed during initialization (null if using iroh defaults)
  String? _customRelayUrl;

  /// Get the active relay URL (null before initialization)
  String? get activeRelayUrl => _getEffectiveRelayUrl();

  /// Get the effective relay URL from cached event data (no FFI call)
  String? _getEffectiveRelayUrl() {
    return _cachedRelayUrl ?? _customRelayUrl;
  }

  /// Extract the relay URL from a nodeAddr JSON string.
  /// The nodeAddr format is: {"id": "...", "addrs": [{"Relay": "https://..."}, {"Ip": "..."}]}
  String? _extractRelayUrlFromNodeAddr(String nodeAddrJson) {
    try {
      final decoded = json.decode(nodeAddrJson);
      if (decoded is! Map<String, dynamic>) return null;

      final addrs = decoded['addrs'];
      if (addrs is! List) return null;

      // Find the first Relay address
      for (final addr in addrs) {
        if (addr is Map<String, dynamic> && addr.containsKey('Relay')) {
          return addr['Relay'] as String?;
        }
      }
    } catch (e) {
      debugPrint('[P2P] Failed to extract relay URL from nodeAddr: $e');
    }
    return null;
  }

  /// Initialize the P2P host.
  ///
  /// [relayUrl] - Optional custom iroh relay URL. If not provided, uses
  /// the build-time IROH_RELAY_URL or falls back to [_defaultRelayUrl].
  Future<void> initialize({String? relayUrl}) async {
    if (_isInitialized) return;

    // Use provided URL, or custom from env, or our default relay
    final effectiveRelayUrl = relayUrl ??
        (_customIrohRelayUrl.isNotEmpty
            ? _customIrohRelayUrl
            : _defaultRelayUrl);
    _customRelayUrl = effectiveRelayUrl;

    try {
      debugPrint(
          '[P2P] Initializing iroh-based P2P Host with relay: $effectiveRelayUrl');

      // Initialize Host via FRB - returns (P2PHost, String)
      final (host, nodeId) = P2PHost.init(relayUrl: effectiveRelayUrl);
      _host = host;
      _nodeId = nodeId;

      debugPrint('[P2P] Host started with NodeID: $nodeId');

      // Start Event Stream
      _eventSubscription = _host!.eventStream().listen((event) {
        debugPrint('[P2P] Event: $event');

        if (event.startsWith('connected:')) {
          // Format: "connected:<peer_id>:<connection_type>"
          final parts = event.substring('connected:'.length).split(':');
          final peerId = parts.first;
          final connectionType = parts.length > 1 ? parts[1] : 'unknown';
          debugPrint('[P2P] Peer connected: $peerId ($connectionType)');
          _connectedPeers.add(peerId);
          _currentConnectionType = _parseConnectionType(connectionType);
          _autoReconnectAttempts = 0;
          _autoReconnectTimer?.cancel();
          _peerConnectedController.add(peerId);
          _emitStatus();
        } else if (event.startsWith('connection_type_changed:')) {
          final parts =
              event.substring('connection_type_changed:'.length).split(':');
          final peerId = parts.first;
          final connectionType = parts.length > 1 ? parts[1] : 'unknown';
          debugPrint(
              '[P2P] Connection type changed: $peerId -> $connectionType');
          _currentConnectionType = _parseConnectionType(connectionType);
          _emitStatus();
        } else if (event.startsWith('disconnected:')) {
          final peerId = event.substring('disconnected:'.length);
          debugPrint('[P2P] Peer disconnected: $peerId');
          _connectedPeers.remove(peerId);
          if (_connectedPeers.isEmpty) {
            _currentConnectionType = P2pConnectionType.none;
          }
          _emitStatus();
          _scheduleAutoReconnect();
        } else if (event == 'relay_connected') {
          debugPrint('[P2P] Connected to relay');
          _isRelayConnected = true;
          _emitStatus();
        } else if (event.startsWith('ready:')) {
          final nodeAddrJson = event.substring('ready:'.length);
          debugPrint('[P2P] Node ready with addr: $nodeAddrJson');
          _nodeAddr = nodeAddrJson;
          _cachedRelayUrl = _extractRelayUrlFromNodeAddr(nodeAddrJson);
          _emitStatus();
        }
      });

      _isInitialized = true;
      _emitStatus();

      // Get initial node address (async FFI call, runs on worker thread)
      _nodeAddr = await _host!.getNodeAddr();
      debugPrint('[P2P] Initial node addr: $_nodeAddr');
    } catch (e) {
      debugPrint('[P2P] Failed to initialize: $e');
      rethrow;
    }
  }

  void _emitStatus() {
    _statusController.add(status);
  }

  /// Schedule an auto-reconnect attempt after a disconnect event.
  /// Uses the cached [_lastDialedEndpointAddr] to re-dial the peer.
  /// Caps attempts at [_maxAutoReconnectAttempts] to avoid infinite loops.
  void _scheduleAutoReconnect() {
    final addr = _lastDialedEndpointAddr;
    if (addr == null) return;
    if (_autoReconnectAttempts >= _maxAutoReconnectAttempts) {
      debugPrint(
          '[P2P] Auto-reconnect attempts exhausted ($_autoReconnectAttempts/$_maxAutoReconnectAttempts)');
      return;
    }

    // Cancel any pending reconnect timer
    _autoReconnectTimer?.cancel();

    _autoReconnectAttempts++;
    debugPrint(
        '[P2P] Scheduling auto-reconnect attempt $_autoReconnectAttempts/$_maxAutoReconnectAttempts '
        'in ${_autoReconnectDelay.inSeconds}s');

    _autoReconnectTimer = Timer(_autoReconnectDelay, () async {
      // Don't reconnect if already connected or disposed
      if (_host == null || !_isInitialized) return;
      if (isConnectedToPeer(addr)) {
        debugPrint('[P2P] Already reconnected, skipping auto-reconnect');
        return;
      }

      try {
        debugPrint('[P2P] Auto-reconnecting...');
        await dial(addr);
      } catch (e) {
        debugPrint('[P2P] Auto-reconnect failed: $e');
        // Schedule another attempt if we haven't exhausted retries
        _scheduleAutoReconnect();
      }
    });
  }

  /// Dial a peer using their EndpointAddr JSON.
  /// This is the primary way to connect to a peer in iroh.
  Future<void> dial(String endpointAddrJson) async {
    if (_host == null) throw Exception("P2P host not initialized");
    debugPrint('[P2P] Dialing endpoint: $endpointAddrJson');
    await _host!.dial(endpointAddrJson: endpointAddrJson);
  }

  /// Extract the node ID from an EndpointAddr JSON string.
  /// Returns null if the JSON is invalid or doesn't contain an id field.
  String? _extractNodeIdFromEndpointAddr(String endpointAddrJson) {
    try {
      final decoded = json.decode(endpointAddrJson);
      if (decoded is Map<String, dynamic>) {
        return decoded['id'] as String?;
      }
    } catch (e) {
      debugPrint('[P2P] Failed to extract node ID from EndpointAddr: $e');
    }
    return null;
  }

  /// Check if we're currently connected to a peer.
  /// The peer can be specified as either a bare node ID or an EndpointAddr JSON.
  bool isConnectedToPeer(String peer) {
    // If it looks like JSON, extract the node ID
    final nodeId =
        peer.startsWith('{') ? _extractNodeIdFromEndpointAddr(peer) : peer;
    if (nodeId == null) return false;
    return _connectedPeers.contains(nodeId);
  }

  /// Ensure we're connected to a peer, initializing and dialing if necessary.
  /// The peer should be an EndpointAddr JSON string.
  Future<void> ensureConnected(String endpointAddrJson) async {
    // Auto-initialize if not already done
    if (!_isInitialized) {
      debugPrint('[P2P] Auto-initializing P2P service...');
      await initialize();
    }

    if (_host == null) throw Exception("P2P host initialization failed");

    // Cache for auto-reconnect on disconnect
    _lastDialedEndpointAddr = endpointAddrJson;

    // Check if already connected
    if (isConnectedToPeer(endpointAddrJson)) {
      debugPrint('[P2P] Already connected to peer');
      _autoReconnectAttempts = 0;
      return;
    }

    // Not connected, dial the peer
    debugPrint('[P2P] Not connected, dialing peer...');
    await dial(endpointAddrJson);

    // Wait briefly for the connection event to be processed
    // This gives time for the 'connected:' event to be received
    await Future.delayed(const Duration(milliseconds: 100));

    // Reset reconnect counter on successful dial
    _autoReconnectAttempts = 0;
  }

  /// Get this node's EndpointAddr as JSON for sharing.
  Future<String?> getNodeAddr() async {
    if (_host == null) return null;
    return await _host!.getNodeAddr();
  }

  /// Send a pairing request to a specific peer.
  /// The peer can be either a node_id string or an EndpointAddr JSON.
  Future<Map<String, dynamic>> sendPairingRequest({
    required String peer,
    required String claimCode,
    required String deviceName,
    required String deviceType,
  }) async {
    if (_host == null) throw Exception("P2P host not initialized");

    final normalized = await _normalizePeerForRequest(peer);
    debugPrint('[P2P] Sending pairing request to ${normalized.nodeId}');

    final req = FlutterPairingRequest(
      claimCode: claimCode,
      deviceName: deviceName,
      deviceType: deviceType,
      deviceOs: kIsWeb ? 'web' : Platform.operatingSystem,
    );

    final res =
        await _host!.sendPairingRequest(peer: normalized.nodeId, req: req);

    if (res.success) {
      return {
        'mediaToken': res.mediaToken,
        'accessToken': res.accessToken,
        'deviceToken': res.deviceToken,
      };
    } else {
      throw Exception(res.error ?? "Pairing failed");
    }
  }

  /// Get network statistics
  Future<FlutterNetworkStats?> getNetworkStats() async {
    if (_host == null) return null;
    return await _host!.getNetworkStats();
  }

  /// Send a GraphQL request to the server over P2P.
  /// Returns the parsed JSON response data or throws on error.
  Future<Map<String, dynamic>> sendGraphQLRequest({
    required String peer,
    required String query,
    Map<String, dynamic>? variables,
    String? operationName,
    String? authToken,
  }) async {
    if (_host == null) throw Exception("P2P host not initialized");

    final normalized = await _normalizePeerForRequest(peer);

    debugPrint('[P2P] Sending GraphQL request to ${normalized.nodeId}');

    // Convert variables to JSON string if provided
    String? variablesJson;
    if (variables != null) {
      variablesJson = _encodeJson(variables);
    }

    final req = FlutterGraphQLRequest(
      query: query,
      variables: variablesJson,
      operationName: operationName,
      authToken: authToken,
    );

    final res =
        await _host!.sendGraphqlRequest(peer: normalized.nodeId, req: req);

    // Parse the response
    if (res.errors != null) {
      final errors = _decodeJson(res.errors!);
      if (errors is List && errors.isNotEmpty) {
        final firstError = errors.first;
        throw Exception(firstError['message'] ?? 'GraphQL error');
      }
    }

    if (res.data != null) {
      final data = _decodeJson(res.data!);
      if (data is Map<String, dynamic>) {
        return data;
      }
    }

    return {};
  }

  String? _encodeJson(Object? value) {
    if (value == null) return null;
    try {
      return const JsonEncoder().convert(value);
    } catch (e) {
      debugPrint('[P2P] Failed to encode JSON: $e');
      return null;
    }
  }

  dynamic _decodeJson(String json) {
    try {
      return const JsonDecoder().convert(json);
    } catch (e) {
      debugPrint('[P2P] Failed to decode JSON: $e');
      return null;
    }
  }

  /// Send an HLS request to the server over P2P.
  /// Returns the complete response with header and data.
  Future<FlutterHlsResponse> sendHlsRequest({
    required String peer,
    required String sessionId,
    required String path,
    int? rangeStart,
    int? rangeEnd,
    String? authToken,
  }) async {
    if (_host == null) throw Exception("P2P host not initialized");

    final sw = Stopwatch()..start();
    final normalized = await _normalizePeerForRequest(peer);
    final normalizeMs = sw.elapsedMilliseconds;

    final req = FlutterHlsRequest(
      sessionId: sessionId,
      path: path,
      rangeStart: rangeStart != null ? BigInt.from(rangeStart) : null,
      rangeEnd: rangeEnd != null ? BigInt.from(rangeEnd) : null,
      authToken: authToken,
    );

    final result =
        await _host!.sendHlsRequest(peer: normalized.nodeId, req: req);
    final totalMs = sw.elapsedMilliseconds;
    final ffiMs = totalMs - normalizeMs;

    debugPrint(
      '[p2p_metrics_dart] sendHlsRequest normalize_ms=$normalizeMs ffi_ms=$ffiMs total_ms=$totalMs bytes=${result.data.length} session=$sessionId path=$path',
    );

    return result;
  }

  /// Send a streaming HLS request to the server over P2P.
  /// Returns a stream of FlutterHlsStreamEvent (Header, Chunk, End, Error).
  Stream<FlutterHlsStreamEvent> sendHlsRequestStreaming({
    required String peer,
    required String sessionId,
    required String path,
    int? rangeStart,
    int? rangeEnd,
    String? authToken,
  }) async* {
    if (_host == null) throw Exception("P2P host not initialized");

    final sw = Stopwatch()..start();
    final normalized = await _normalizePeerForRequest(peer);
    final normalizeMs = sw.elapsedMilliseconds;

    debugPrint(
      '[p2p_metrics_dart] sendHlsRequestStreaming normalize_ms=$normalizeMs session=$sessionId path=$path',
    );

    final req = FlutterHlsRequest(
      sessionId: sessionId,
      path: path,
      rangeStart: rangeStart != null ? BigInt.from(rangeStart) : null,
      rangeEnd: rangeEnd != null ? BigInt.from(rangeEnd) : null,
      authToken: authToken,
    );

    yield* _host!.sendHlsRequestStreaming(peer: normalized.nodeId, req: req);
  }

  /// Reset the P2P host for re-initialization.
  /// This allows changing the relay URL by calling initialize() again.
  void reset() {
    _autoReconnectTimer?.cancel();
    _autoReconnectAttempts = 0;
    _lastDialedEndpointAddr = null;
    _eventSubscription?.cancel();
    _eventSubscription = null;
    _host = null;
    _isInitialized = false;
    _isRelayConnected = false;
    _nodeAddr = null;
    _nodeId = null;
    _customRelayUrl = null;
    _currentConnectionType = P2pConnectionType.none;
    _cachedRelayUrl = null;
    _connectedPeers.clear();
    _emitStatus();
  }

  Future<({String nodeId, String? endpointAddrJson})> _normalizePeerForRequest(
    String peer,
  ) async {
    final endpointAddrJson = peer.startsWith('{') ? peer : null;
    final nodeId = endpointAddrJson != null
        ? _extractNodeIdFromEndpointAddr(endpointAddrJson)
        : peer;

    if (nodeId == null || nodeId.isEmpty) {
      throw Exception('Invalid peer address');
    }

    if (endpointAddrJson != null) {
      await ensureConnected(endpointAddrJson);
      await _waitForConnectedPeer(nodeId);
      return (nodeId: nodeId, endpointAddrJson: endpointAddrJson);
    }

    // If the caller provided a bare node ID, wait briefly for any in-flight
    // connection (for example from a prior dial()) before sending the request.
    await _waitForConnectedPeer(nodeId);
    return (nodeId: nodeId, endpointAddrJson: null);
  }

  Future<void> _waitForConnectedPeer(String nodeId,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!isConnectedToPeer(nodeId)) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
            'Timed out waiting for peer connection: $nodeId');
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> dispose() async {
    _autoReconnectTimer?.cancel();
    // Cancel before closing the controllers below: the Rust host is only
    // dropped when it is garbage collected, not synchronously here, so a
    // live subscription can otherwise still fire into a closed controller.
    await _eventSubscription?.cancel();
    _eventSubscription = null;
    // Rust host is dropped when P2PHost is garbage collected
    _host = null;
    _isInitialized = false;
    await _statusController.close();
    await _peerConnectedController.close();
  }
}
