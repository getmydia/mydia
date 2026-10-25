/// Device pairing service using P2P.
///
/// This service orchestrates the complete device pairing flow using
/// iroh-based P2P networking with relay-based discovery.
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../auth/auth_storage.dart';
import '../p2p/p2p_service.dart';
import '../relay/relay_api_client.dart';

/// Data parsed from a QR code for device pairing.
///
/// The QR code contains JSON with the following fields:
/// - node_addr: The server's EndpointAddr JSON (for direct dialing)
/// - claim_code: The pairing claim code (for authentication)
/// - instance_id: (optional) The server's unique instance ID
class QrPairingData {
  /// The server's EndpointAddr JSON for direct P2P connection.
  final String nodeAddr;

  /// The pairing claim code.
  final String claimCode;

  /// The server's unique instance ID (optional).
  final String? instanceId;

  const QrPairingData({
    required this.nodeAddr,
    required this.claimCode,
    this.instanceId,
  });

  /// Parses QR code content into [QrPairingData].
  ///
  /// Returns null if the content is not valid JSON or is missing required fields.
  static QrPairingData? tryParse(String content) {
    try {
      final json = jsonDecode(content) as Map<String, dynamic>;

      final nodeAddr = json['node_addr'] as String?;
      final claimCode = json['claim_code'] as String?;
      final instanceId = json['instance_id'] as String?;

      if (nodeAddr == null || claimCode == null) {
        return null;
      }

      return QrPairingData(
        nodeAddr: nodeAddr,
        claimCode: claimCode,
        instanceId: instanceId,
      );
    } catch (e) {
      return null;
    }
  }
}

/// Storage keys for pairing credentials.
abstract class _StorageKeys {
  static const serverUrl = 'pairing_server_url';
  static const deviceId = 'pairing_device_id';
  static const mediaToken = 'pairing_media_token';
  static const mediaTokenExpiry = 'pairing_media_token_expiry';
  static const accessToken = 'pairing_access_token';
  static const deviceToken = 'pairing_device_token';
  static const directUrls = 'pairing_direct_urls';
  static const certFingerprint = 'pairing_cert_fingerprint';
  static const instanceName = 'pairing_instance_name';
  static const serverPublicKey = 'server_public_key';
  static const instanceId = 'instance_id';
  static const serverNodeAddr = 'server_node_addr';
}

/// Where pairing is, for the progress line under the code field. The service
/// reports its own steps; the login controller adds the ones around it
/// ([lookingUpCode], [validatingQr], [paired]). The screen words them, so this
/// carries no text.
enum PairingStep {
  lookingUpCode,
  validatingQr,
  resolvingCode,
  initializing,
  connecting,
  submitting,
  succeeded,
  paired,
}

/// Why pairing stopped. [other] carries the exception text in
/// [PairingFailure.detail], which is diagnostic and shown as it is.
enum PairingFailureKind {
  serviceUnavailable,
  cannotConnect,
  invalidServerAddress,
  invalidQrServerAddress,
  missingTokens,
  invalidCode,
  tooManyAttempts,
  serverOffline,
  timedOut,
  other,
}

class PairingFailure {
  const PairingFailure(this.kind, {this.detail});
  final PairingFailureKind kind;
  final String? detail;
}

/// Result of a pairing operation.
class PairingResult {
  final bool success;

  /// Set when [success] is false.
  final PairingFailure? failure;
  final PairingCredentials? credentials;

  /// Whether the connection is via P2P.
  final bool isP2PMode;

  const PairingResult._({
    required this.success,
    this.failure,
    this.credentials,
    this.isP2PMode = false,
  });

  factory PairingResult.success(PairingCredentials credentials,
      {bool isP2PMode = false}) {
    return PairingResult._(
        success: true, credentials: credentials, isP2PMode: isP2PMode);
  }

  factory PairingResult.failure(PairingFailureKind kind, {String? detail}) {
    return PairingResult._(
      success: false,
      failure: PairingFailure(kind, detail: detail),
    );
  }
}

/// Credentials obtained from successful pairing.
class PairingCredentials {
  /// The server URL (p2p:// URI for P2P mode).
  final String serverUrl;

  /// The device ID assigned by the server.
  final String deviceId;

  /// The media access token for streaming (typ: media_access).
  final String mediaToken;

  /// The access token for GraphQL/API requests (typ: access).
  final String accessToken;

  /// The device token for reconnection authentication.
  final String? deviceToken;

  /// The server's static public key (32 bytes).
  final Uint8List serverPublicKey;

  /// Direct URLs for connecting to the instance.
  final List<String> directUrls;

  /// Certificate fingerprint for TLS validation.
  final String? certFingerprint;

  /// Instance name (friendly identifier).
  final String? instanceName;

  /// Instance ID for P2P connections.
  final String? instanceId;

  /// The server's EndpointAddr JSON for P2P reconnection.
  final String? serverNodeAddr;

  const PairingCredentials({
    required this.serverUrl,
    required this.deviceId,
    required this.mediaToken,
    required this.accessToken,
    this.deviceToken,
    required this.serverPublicKey,
    required this.directUrls,
    this.certFingerprint,
    this.instanceName,
    this.instanceId,
    this.serverNodeAddr,
  });
}

/// Service for pairing new devices with a Mydia server.
///
/// This service handles the complete pairing flow using P2P:
/// - QR code pairing: Uses node_addr from QR to connect directly
/// - Claim code pairing: Uses relay API to get node_addr, then dials directly
class PairingService {
  PairingService({
    AuthStorage? authStorage,
    P2pService? p2pService,
    RelayApiClient? relayClient,
  })  : _authStorage = authStorage ?? getAuthStorage(),
        _p2pService = p2pService,
        _relayClient = relayClient;

  final AuthStorage _authStorage;
  final P2pService? _p2pService;
  final RelayApiClient? _relayClient;

  /// Pairs this device using a claim code via relay API lookup.
  ///
  /// This method:
  /// 1. Resolves the claim code to get the server's EndpointAddr via relay API
  /// 2. Initializes the P2P host
  /// 3. Dials the server using the EndpointAddr
  /// 4. Sends a pairing request
  /// 5. Returns the credentials; the caller decides where they are stored
  Future<PairingResult> pairWithClaimCodeOnly({
    required String claimCode,
    required String deviceName,
    String? platform,
    void Function(PairingStep step)? onStatusUpdate,
  }) async {
    try {
      final devicePlatform = platform ?? _detectPlatform();
      debugPrint('[PairingService] === PAIRING VIA CLAIM CODE ===');
      // The claim code authenticates a pairing request, so it stays out of
      // the logs. Device metadata is enough to follow a pairing through.
      debugPrint(
          '[PairingService] deviceName=$deviceName, platform=$devicePlatform');

      // Use the injected P2P service - it must be provided and initialized
      final p2pService = _p2pService;
      if (p2pService == null) {
        return PairingResult.failure(PairingFailureKind.serviceUnavailable);
      }

      // 1. Resolve claim code via relay API to get server's EndpointAddr
      onStatusUpdate?.call(PairingStep.resolvingCode);
      final relayClient = _relayClient ?? RelayApiClient();
      final resolveResult = await relayClient.resolveClaimCode(claimCode);
      debugPrint(
          '[PairingService] Resolved node_addr: ${resolveResult.nodeAddr}');

      // 2. Initialize the P2P host
      onStatusUpdate?.call(PairingStep.initializing);
      await p2pService.initialize();

      // 3. Dial the server using EndpointAddr
      onStatusUpdate?.call(PairingStep.connecting);
      try {
        await p2pService.dial(resolveResult.nodeAddr);
        debugPrint('[PairingService] Dialed server successfully');
      } catch (e) {
        debugPrint('[PairingService] Failed to dial server: $e');
        return PairingResult.failure(PairingFailureKind.cannotConnect);
      }

      final peerId = _extractNodeId(resolveResult.nodeAddr);
      if (peerId == null) {
        debugPrint(
            '[PairingService] Could not extract node ID from resolved node_addr');
        return PairingResult.failure(PairingFailureKind.invalidServerAddress);
      }
      debugPrint('[PairingService] Using peer node ID: $peerId');

      // 4. Send pairing request
      onStatusUpdate?.call(PairingStep.submitting);
      final result = await p2pService.sendPairingRequest(
        peer: peerId,
        claimCode: claimCode,
        deviceName: deviceName,
        deviceType: devicePlatform,
      );

      final mediaToken = result['mediaToken'] as String?;
      final accessToken = result['accessToken'] as String?;
      final deviceToken = result['deviceToken'] as String?;

      if (accessToken == null || mediaToken == null) {
        return PairingResult.failure(PairingFailureKind.missingTokens);
      }

      // In P2P mode, serverUrl is a p2p:// URI
      final credentials = PairingCredentials(
        serverUrl: 'p2p://mydia',
        deviceId: 'paired-device',
        mediaToken: mediaToken,
        accessToken: accessToken,
        deviceToken: deviceToken,
        serverPublicKey: Uint8List(0),
        directUrls: [],
        instanceId: resolveResult.instanceId,
        serverNodeAddr: resolveResult.nodeAddr,
      );

      onStatusUpdate?.call(PairingStep.succeeded);
      return PairingResult.success(credentials, isP2PMode: true);
    } on InvalidClaimCodeException {
      return PairingResult.failure(PairingFailureKind.invalidCode);
    } on RateLimitedException {
      return PairingResult.failure(PairingFailureKind.tooManyAttempts);
    } on ServerNotOnlineException {
      return PairingResult.failure(PairingFailureKind.serverOffline);
    } on TimeoutException catch (e) {
      debugPrint('[PairingService] Timeout: $e');
      return PairingResult.failure(PairingFailureKind.timedOut);
    } catch (e) {
      debugPrint('[PairingService] Error: $e');
      return PairingResult.failure(PairingFailureKind.other, detail: '$e');
    }
  }

  /// Pairs this device using QR code data.
  ///
  /// With iroh, the QR code contains the server's EndpointAddr JSON directly.
  /// We dial the server and send the pairing request.
  Future<PairingResult> pairWithQrData({
    required QrPairingData qrData,
    required String deviceName,
    String? platform,
    void Function(PairingStep step)? onStatusUpdate,
  }) async {
    try {
      final devicePlatform = platform ?? _detectPlatform();
      debugPrint('[PairingService] === PAIRING VIA QR CODE ===');
      debugPrint('[PairingService] instanceId=${qrData.instanceId}');
      // Claim code deliberately omitted; see the note in the claim-code path.
      debugPrint('[PairingService] deviceName=$deviceName');

      final p2pService = _p2pService;
      if (p2pService == null) {
        return PairingResult.failure(PairingFailureKind.serviceUnavailable);
      }

      // Initialize the host
      onStatusUpdate?.call(PairingStep.initializing);
      await p2pService.initialize();

      // Dial the server directly using the EndpointAddr from QR
      onStatusUpdate?.call(PairingStep.connecting);
      try {
        await p2pService.dial(qrData.nodeAddr);
        debugPrint('[PairingService] Dialed server successfully');
      } catch (e) {
        debugPrint('[PairingService] Failed to dial server: $e');
        return PairingResult.failure(PairingFailureKind.cannotConnect);
      }

      final peerId = _extractNodeId(qrData.nodeAddr);
      if (peerId == null) {
        debugPrint(
            '[PairingService] Could not extract node ID from QR node_addr');
        return PairingResult.failure(PairingFailureKind.invalidQrServerAddress);
      }
      debugPrint('[PairingService] Using peer node ID: $peerId');

      // Send pairing request
      onStatusUpdate?.call(PairingStep.submitting);
      final result = await p2pService.sendPairingRequest(
        peer: peerId,
        claimCode: qrData.claimCode,
        deviceName: deviceName,
        deviceType: devicePlatform,
      );

      final mediaToken = result['mediaToken'] as String?;
      final accessToken = result['accessToken'] as String?;
      final deviceToken = result['deviceToken'] as String?;

      if (accessToken == null || mediaToken == null) {
        return PairingResult.failure(PairingFailureKind.missingTokens);
      }

      // In P2P mode, serverUrl is a p2p:// URI
      final credentials = PairingCredentials(
        serverUrl: 'p2p://mydia',
        deviceId: 'paired-device',
        mediaToken: mediaToken,
        accessToken: accessToken,
        deviceToken: deviceToken,
        serverPublicKey: Uint8List(0),
        directUrls: [],
        instanceId: qrData.instanceId,
        serverNodeAddr: qrData.nodeAddr,
      );

      onStatusUpdate?.call(PairingStep.succeeded);
      return PairingResult.success(credentials, isP2PMode: true);
    } on TimeoutException catch (e) {
      debugPrint('[PairingService] Timeout: $e');
      return PairingResult.failure(PairingFailureKind.timedOut);
    } catch (e) {
      debugPrint('[PairingService] Error: $e');
      return PairingResult.failure(PairingFailureKind.other, detail: '$e');
    }
  }

  /// Detects the current platform.
  String _detectPlatform() {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform.name.toLowerCase();
  }

  /// Extract node ID from EndpointAddr JSON.
  String? _extractNodeId(String endpointAddrJson) {
    try {
      final decoded = jsonDecode(endpointAddrJson);
      if (decoded is Map<String, dynamic>) {
        return decoded['id'] as String?;
      }
    } catch (e) {
      debugPrint('[PairingService] Failed to parse endpoint address: $e');
    }
    return null;
  }

  /// Clears stored pairing credentials.
  ///
  /// The deletes run concurrently, not sequentially, and each is wrapped in
  /// [Future.sync] so a delete that throws before it even returns a Future
  /// cannot abort the list before it starts. Either failure mode, sequential
  /// awaits or an eagerly-built list that a synchronous throw cuts short,
  /// would let one bad delete strand every key after it, and
  /// [_StorageKeys.deviceToken] mints fresh access tokens through a
  /// deliberately unauthenticated server mutation, so stranding it would
  /// leave the server reachable after the user signed out. `Future.wait`
  /// starts every delete and, with its default `eagerError: false`, waits
  /// for all of them to settle before reporting failure, so neither an
  /// asynchronous rejection nor a synchronous throw from any one key can
  /// strand the rest.
  Future<void> clearCredentials() async {
    await Future.wait([
      Future.sync(() => _authStorage.delete(_StorageKeys.serverUrl)),
      Future.sync(() => _authStorage.delete(_StorageKeys.deviceId)),
      Future.sync(() => _authStorage.delete(_StorageKeys.mediaToken)),
      Future.sync(() => _authStorage.delete(_StorageKeys.mediaTokenExpiry)),
      Future.sync(() => _authStorage.delete(_StorageKeys.accessToken)),
      Future.sync(() => _authStorage.delete(_StorageKeys.deviceToken)),
      Future.sync(() => _authStorage.delete(_StorageKeys.directUrls)),
      Future.sync(() => _authStorage.delete(_StorageKeys.certFingerprint)),
      Future.sync(() => _authStorage.delete(_StorageKeys.instanceName)),
      Future.sync(() => _authStorage.delete(_StorageKeys.serverPublicKey)),
      Future.sync(() => _authStorage.delete(_StorageKeys.instanceId)),
      Future.sync(() => _authStorage.delete(_StorageKeys.serverNodeAddr)),
    ]);
  }
}
