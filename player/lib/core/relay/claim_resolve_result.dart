/// Exception thrown when the server for a claim code is not online.
class ServerNotOnlineException implements Exception {
  final String message;
  ServerNotOnlineException(this.message);

  @override
  String toString() => message;
}

/// Result of resolving a claim code via the relay API.
///
/// Under the v2 API the relay returns a sealed blob rather than a node address,
/// and the player opens it locally with keys derived from the claim code.
class ClaimResolveResult {
  /// The server's EndpointAddr as a JSON string.
  /// Can be passed directly to P2pService.dial().
  final String nodeAddr;

  /// The server's instance ID, when the relay returned a sealed v2 claim.
  /// Null on the v1 fallback path, which carried no instance ID.
  final String? instanceId;

  ClaimResolveResult({
    required this.nodeAddr,
    this.instanceId,
  });

  factory ClaimResolveResult.fromV1Json(Map<String, dynamic> json) {
    final nodeAddr = json['node_addr'] as String?;
    if (nodeAddr == null) {
      throw FormatException(
        'Invalid response from relay: missing node_addr. Response: $json',
      );
    }
    return ClaimResolveResult(nodeAddr: nodeAddr);
  }
}

/// Thrown when a sealed claim is found but fails to decrypt.
///
/// A wrong code cannot produce a lookup hit short of a 256-bit collision, so
/// this means the stored blob was altered. It is the one condition that points
/// at the relay rather than at the user.
class TamperedClaimException implements Exception {
  @override
  String toString() =>
      'The pairing data could not be verified. Generate a new code and try again.';
}
