import 'dart:convert';

import 'auth_storage.dart';

/// Service for storing and retrieving SSL certificate fingerprints.
///
/// Uses the same secure storage mechanism as auth tokens to persist
/// certificate fingerprints for each Mydia instance. This enables
/// certificate pinning for self-signed certificates.
class CertStorage {
  /// [storage] is injectable for tests and for session teardown, which builds
  /// every credential store over one storage instance.
  CertStorage({AuthStorage? storage}) : _storage = storage ?? getAuthStorage();

  final AuthStorage _storage;

  static const _fingerprintsKey = 'cert_fingerprints';

  /// Store a certificate fingerprint for an instance.
  ///
  /// The [instanceId] should be a unique identifier for the instance
  /// (e.g., the server URL or a device ID). The [fingerprint] is the
  /// SHA-256 hash of the certificate in hex format.
  Future<void> storeFingerprint(String instanceId, String fingerprint) async {
    final fingerprints = await _getFingerprints();
    fingerprints[instanceId] = fingerprint;
    await _saveFingerprints(fingerprints);
  }

  /// Get the stored certificate fingerprint for an instance.
  ///
  /// Returns null if no fingerprint has been stored for this instance.
  Future<String?> getFingerprint(String instanceId) async {
    final fingerprints = await _getFingerprints();
    return fingerprints[instanceId];
  }

  /// Remove the stored certificate fingerprint for an instance.
  Future<void> removeFingerprint(String instanceId) async {
    final fingerprints = await _getFingerprints();
    fingerprints.remove(instanceId);
    await _saveFingerprints(fingerprints);
  }

  /// Clear all stored certificate fingerprints.
  Future<void> clearAll() async {
    await _storage.delete(_fingerprintsKey);
  }

  /// Get all stored fingerprints as a map.
  Future<Map<String, String>> _getFingerprints() async {
    final json = await _storage.read(_fingerprintsKey);
    if (json == null) {
      return {};
    }

    try {
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, value.toString()));
    } catch (e) {
      // If JSON is corrupted, return empty map
      return {};
    }
  }

  /// Save the fingerprints map to storage.
  Future<void> _saveFingerprints(Map<String, String> fingerprints) async {
    final json = jsonEncode(fingerprints);
    await _storage.write(_fingerprintsKey, json);
  }
}
