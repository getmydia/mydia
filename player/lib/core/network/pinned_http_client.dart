import 'dart:io';

import 'cert_verifier.dart';
import '../auth/cert_storage.dart';

/// HTTP client factory that creates clients with certificate pinning.
///
/// This enables secure connections to Mydia instances using self-signed
/// certificates by verifying the certificate fingerprint matches the
/// stored fingerprint from the initial pairing or first connection.
///
/// ## Usage Patterns
///
/// ### Pattern 1: Pinned connection (fingerprint already trusted)
/// ```dart
/// final client = await PinnedHttpClient.createClient('https://mydia.example.com');
/// // Client will reject any certificate that doesn't match stored fingerprint
/// ```
///
/// ### Pattern 2: First-time connection with TOFU
/// ```dart
/// final client = await PinnedHttpClient.createClient(
///   'https://mydia.example.com',
///   allowUnknown: true, // Accept on first connection
/// );
/// // After connection succeeds, verify and store fingerprint
/// ```
///
/// ### Pattern 3: Pre-verified fingerprint (recommended)
/// ```dart
/// // Before creating client, verify certificate separately
/// final verifier = CertVerifier();
/// // ... get certificate somehow (e.g., from initial handshake)
/// final result = await verifier.verifyCertificate(cert, instanceId);
/// if (result.verified || userAcceptsTrust) {
///   await verifier.trustCertificate(cert, instanceId);
///   final client = await PinnedHttpClient.createClient(instanceId);
/// }
/// ```
class PinnedHttpClient {
  final CertStorage _certStorage = CertStorage();

  /// Creates an HTTP client with certificate pinning for an instance.
  ///
  /// The [instanceId] is used to look up the stored certificate fingerprint,
  /// typically the server URL (e.g., 'https://mydia.example.com').
  ///
  /// If [allowUnknown] is true, the client will accept certificates on
  /// first connection (when no fingerprint is stored). This is useful for
  /// initial pairing. The caller should verify the certificate fingerprint
  /// after the connection and store it using [CertVerifier.trustCertificate].
  ///
  /// If [allowUnknown] is false (default), the client will reject any
  /// certificate that doesn't match a stored fingerprint.
  ///
  /// **Security Note:** Only set [allowUnknown] to true during initial
  /// pairing when you will verify the fingerprint through another channel
  /// (e.g., TOFU dialog). For normal connections, leave it false.
  Future<HttpClient> createClient(
    String instanceId, {
    bool allowUnknown = false,
  }) async {
    final storedFingerprint = await _certStorage.getFingerprint(instanceId);

    final client = HttpClient();
    client.badCertificateCallback = (cert, host, port) {
      return _verifyCertificate(cert, storedFingerprint, allowUnknown);
    };

    return client;
  }

  /// Verifies a certificate against the stored fingerprint.
  ///
  /// Returns `true` if the certificate should be trusted, `false` otherwise.
  bool _verifyCertificate(
    X509Certificate cert,
    String? storedFingerprint,
    bool allowUnknown,
  ) {
    final fingerprint = CertVerifier.computeFingerprint(cert);

    if (storedFingerprint == null) {
      // No stored fingerprint - first connection
      return allowUnknown;
    }

    // Verify the fingerprint matches
    return fingerprint == storedFingerprint;
  }

  /// Computes the SHA-256 fingerprint of a certificate.
  ///
  /// Returns the fingerprint as a lowercase hex string with colons
  /// separating each byte (e.g., "aa:bb:cc:dd:...").
  ///
  /// This is a convenience wrapper around [CertVerifier.computeFingerprint].
  static String computeFingerprint(X509Certificate cert) {
    return CertVerifier.computeFingerprint(cert);
  }
}
