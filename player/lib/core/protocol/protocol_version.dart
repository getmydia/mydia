/// Protocol version constants and negotiation for remote access.
///
/// The remote access protocol has multiple independent layers:
///
/// - `relay_protocol` - Relay WebSocket message format
/// - `encryption_protocol` - E2E encryption scheme
/// - `pairing_protocol` - Device pairing handshake
/// - `api_protocol` - Tunneled API request/response format
///
/// ## Multi-Version Support
///
/// Each layer advertises a list of supported versions. Components negotiate
/// the highest mutually-supported major version during handshake.
library;

/// Protocol version constants and negotiation.
class ProtocolVersion {
  ProtocolVersion._();

  /// Supported relay protocol versions.
  static const relayProtocolSupported = ['1.0'];

  /// Supported encryption protocol versions.
  static const encryptionProtocolSupported = ['1.0'];

  /// Supported pairing protocol versions.
  static const pairingProtocolSupported = ['1.0'];

  /// Supported API protocol versions.
  static const apiProtocolSupported = ['1.0'];

  /// All supported protocol versions for negotiation.
  ///
  /// Use this when sending supported versions to the server.
  static Map<String, List<String>> get all => supportedVersions;

  /// Returns all supported versions for each protocol layer.
  static Map<String, List<String>> get supportedVersions => {
        'relay_protocol': relayProtocolSupported,
        'encryption_protocol': encryptionProtocolSupported,
        'pairing_protocol': pairingProtocolSupported,
        'api_protocol': apiProtocolSupported,
      };

  /// Negotiates the best common version for a protocol layer.
  ///
  /// Returns `null` if no common major version is found.
  static String? negotiateVersion(String layer, List<String> serverVersions) {
    final local = supportedVersions[layer] ?? [];

    // Find versions with matching major numbers
    final common = local.where((localVersion) {
      final localMajor = _parseMajor(localVersion);
      return serverVersions.any((serverVersion) {
        final serverMajor = _parseMajor(serverVersion);
        return localMajor == serverMajor;
      });
    }).toList();

    if (common.isEmpty) return null;

    // Return highest common version
    return common.reduce((a, b) => _compareMajor(a, b) > 0 ? a : b);
  }

  /// Negotiates all protocol layers at once.
  ///
  /// Returns a map of negotiated versions, or null for layers that
  /// have no compatible version.
  static Map<String, String?> negotiateAll(
      Map<String, dynamic> serverVersions) {
    return {
      'encryption_protocol': negotiateVersion(
        'encryption_protocol',
        _toStringList(serverVersions['encryption_protocol']),
      ),
      'pairing_protocol': negotiateVersion(
        'pairing_protocol',
        _toStringList(serverVersions['pairing_protocol']),
      ),
      'api_protocol': negotiateVersion(
        'api_protocol',
        _toStringList(serverVersions['api_protocol']),
      ),
    };
  }

  /// Checks server versions and returns mismatch details if incompatible.
  ///
  /// Returns `null` if all versions are compatible.
  static VersionMismatch? checkCompatibility(
      Map<String, dynamic> serverVersions) {
    final mismatches = <VersionInfo>[];

    void check(String layer, List<String> clientVersions) {
      final serverVersionList = _toStringList(serverVersions[layer]);
      if (serverVersionList.isEmpty) return;

      final negotiated = negotiateVersion(layer, serverVersionList);

      if (negotiated == null) {
        mismatches.add(VersionInfo(
          layer: layer,
          clientVersion: clientVersions.join(', '),
          serverVersion: serverVersionList.join(', '),
        ));
      }
    }

    check('relay_protocol', relayProtocolSupported);
    check('encryption_protocol', encryptionProtocolSupported);
    check('pairing_protocol', pairingProtocolSupported);
    check('api_protocol', apiProtocolSupported);

    if (mismatches.isEmpty) return null;

    return VersionMismatch(
      mismatches: mismatches,
      updateRequired: true,
    );
  }

  static List<String> _toStringList(dynamic value) {
    if (value == null) return [];
    if (value is List) return value.cast<String>();
    return [];
  }

  static int _parseMajor(String version) {
    final parts = version.split('.');
    if (parts.isEmpty) return 0;
    return int.tryParse(parts.first) ?? 0;
  }

  static int _compareMajor(String a, String b) {
    return _parseMajor(a) - _parseMajor(b);
  }
}

/// Information about a single version mismatch.
class VersionInfo {
  final String layer;
  final String clientVersion;
  final String serverVersion;

  const VersionInfo({
    required this.layer,
    required this.clientVersion,
    required this.serverVersion,
  });

  @override
  String toString() =>
      'VersionInfo(layer: $layer, client: $clientVersion, server: $serverVersion)';
}

/// Details about version incompatibility.
class VersionMismatch {
  final List<VersionInfo> mismatches;
  final bool updateRequired;

  const VersionMismatch({
    required this.mismatches,
    this.updateRequired = true,
  });

  String get message {
    if (mismatches.isEmpty) return '';
    final layers =
        mismatches.map((m) => m.layer.replaceAll('_', ' ')).join(', ');
    return 'Protocol version mismatch in: $layers. Please update your app.';
  }

  @override
  String toString() =>
      'VersionMismatch(updateRequired: $updateRequired, mismatches: $mismatches)';
}

/// Error thrown when server requires a client update.
class UpdateRequiredError implements Exception {
  final String message;
  final List<Map<String, dynamic>> incompatibleLayers;
  final String? updateUrl;

  const UpdateRequiredError({
    required this.message,
    required this.incompatibleLayers,
    this.updateUrl,
  });

  factory UpdateRequiredError.fromJson(Map<String, dynamic> json) {
    return UpdateRequiredError(
      message: json['message'] as String? ?? 'Update required',
      incompatibleLayers: (json['incompatible_layers'] as List?)
              ?.cast<Map<String, dynamic>>() ??
          [],
      updateUrl: json['update_url'] as String?,
    );
  }

  @override
  String toString() => 'UpdateRequiredError: $message';
}
