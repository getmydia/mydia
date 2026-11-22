import 'dart:io';

import 'package:crypto/crypto.dart';

import '../auth/cert_storage.dart';

/// Result of a certificate verification operation.
class CertVerificationResult {
  /// Whether the certificate passed verification.
  final bool verified;

  /// The computed fingerprint of the certificate.
  final String fingerprint;

  /// Whether this was a first-time connection (no stored fingerprint).
  final bool firstTime;

  /// Error message if verification failed.
  final String? error;

  const CertVerificationResult({
    required this.verified,
    required this.fingerprint,
    required this.firstTime,
    this.error,
  });

  factory CertVerificationResult.verified(
    String fingerprint, {
    bool firstTime = false,
  }) {
    return CertVerificationResult(
      verified: true,
      fingerprint: fingerprint,
      firstTime: firstTime,
    );
  }

  factory CertVerificationResult.failed(String fingerprint, String error) {
    return CertVerificationResult(
      verified: false,
      fingerprint: fingerprint,
      firstTime: false,
      error: error,
    );
  }
}

/// Service for verifying SSL certificates against stored fingerprints.
///
/// This service provides certificate pinning functionality to ensure
/// connections to Mydia instances using self-signed certificates are secure.
///
/// ## Usage
///
/// ```dart
/// final verifier = CertVerifier();
///
/// // Verify a certificate
/// final result = await verifier.verifyCertificate(cert, 'mydia.example.com');
///
/// if (result.verified) {
///   // Certificate is trusted
/// } else if (result.firstTime) {
///   // Show TOFU dialog and store if user accepts
///   if (userAccepts) {
///     await verifier.trustCertificate(cert, 'mydia.example.com');
///   }
/// } else {
///   // Certificate mismatch - reject connection
///   print('Error: ${result.error}');
/// }
/// ```
class CertVerifier {
  final CertStorage _certStorage = CertStorage();

  /// Verifies a certificate against the stored fingerprint for an instance.
  ///
  /// The [instanceId] is typically the server URL (e.g., 'https://mydia.example.com').
  ///
  /// Returns a [CertVerificationResult] indicating:
  /// - `verified: true, firstTime: true` - First connection, no stored fingerprint
  /// - `verified: true, firstTime: false` - Certificate matches stored fingerprint
  /// - `verified: false` - Certificate does not match stored fingerprint
  Future<CertVerificationResult> verifyCertificate(
    X509Certificate cert,
    String instanceId,
  ) async {
    final fingerprint = computeFingerprint(cert);
    final storedFingerprint = await _certStorage.getFingerprint(instanceId);

    if (storedFingerprint == null) {
      // First-time connection - caller should show TOFU dialog
      return CertVerificationResult.verified(fingerprint, firstTime: true);
    }

    if (fingerprint == storedFingerprint) {
      // Certificate matches stored fingerprint
      return CertVerificationResult.verified(fingerprint);
    }

    // Certificate mismatch - potential MITM attack
    return CertVerificationResult.failed(
      fingerprint,
      'Certificate fingerprint mismatch. Expected: $storedFingerprint, Got: $fingerprint',
    );
  }

  /// Trusts a certificate by storing its fingerprint.
  ///
  /// This should be called after the user confirms trust in a TOFU dialog.
  Future<void> trustCertificate(X509Certificate cert, String instanceId) async {
    final fingerprint = computeFingerprint(cert);
    await _certStorage.storeFingerprint(instanceId, fingerprint);
  }

  /// Gets the stored fingerprint for an instance.
  ///
  /// Returns null if no fingerprint is stored.
  Future<String?> getStoredFingerprint(String instanceId) async {
    return _certStorage.getFingerprint(instanceId);
  }

  /// Removes the stored fingerprint for an instance.
  ///
  /// This should be called when the user wants to re-trust a server
  /// or when logging out.
  Future<void> clearFingerprint(String instanceId) async {
    await _certStorage.removeFingerprint(instanceId);
  }

  /// Computes the SHA-256 fingerprint of a certificate.
  ///
  /// Returns the fingerprint as a lowercase hex string with colons
  /// separating each byte (e.g., "aa:bb:cc:dd:...").
  ///
  /// This is a static method so it can be used without creating an instance.
  static String computeFingerprint(X509Certificate cert) {
    final der = cert.der;
    final digest = sha256.convert(der);
    final hex = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join(':');
    return hex;
  }

  /// Formats a fingerprint for display by breaking it into multiple lines.
  ///
  /// This makes long fingerprints easier to read in UI dialogs.
  ///
  /// Example:
  /// ```
  /// aa:bb:cc:dd:ee:ff:00:11
  /// 22:33:44:55:66:77:88:99
  /// ```
  static String formatFingerprint(String fingerprint, {int bytesPerLine = 16}) {
    final parts = fingerprint.split(':');
    final lines = <String>[];

    for (var i = 0; i < parts.length; i += bytesPerLine) {
      final end = i + bytesPerLine < parts.length
          ? i + bytesPerLine
          : parts.length;
      lines.add(parts.sublist(i, end).join(':'));
    }

    return lines.join('\n');
  }
}
