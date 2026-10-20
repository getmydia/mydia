/// Native persistence for the node's Ed25519 secret, in the platform keyring.
///
/// Before this, native platforms generated a new identity on every launch.
/// After an app update the ambient cast sweep then spent a 10 second dial on
/// the player's own previous node ID, still on its device row until
/// re-registration replaced it, and every launch rewrote that row.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../auth/auth_storage_native.dart' show SecretBackend;
import '../storage/secure_storage_options.dart';
import 'p2p_keystore.dart';

const _key = 'p2p_node_secret';

class _SecureStorageBackend implements SecretBackend {
  const _SecureStorageBackend();

  static const _storage = FlutterSecureStorage(
    aOptions: kAndroidSecureStorageOptions,
    mOptions: kMacOsSecureStorageOptions,
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  // Never called by the keystore: the keyring is shared with the auth tokens,
  // and wiping it here would sign the user out.
  @override
  Future<void> deleteAll() => _storage.deleteAll();
}

class NativeP2pKeystore implements P2pKeystore {
  NativeP2pKeystore({SecretBackend? backend})
      : _backend = backend ?? const _SecureStorageBackend();

  final SecretBackend _backend;

  /// Throws on a backend failure or a malformed value, never returns null for
  /// a secret that exists: see [P2pKeystore.read].
  @override
  Future<Uint8List?> read() async {
    final stored = await _backend.read(_key);
    if (stored == null) return null;
    final bytes = base64Decode(stored);
    if (bytes.length != 32) {
      throw FormatException(
          'Stored p2p node secret is ${bytes.length} bytes, expected 32');
    }
    return bytes;
  }

  @override
  Future<void> write(Uint8List secret) =>
      _backend.write(_key, base64Encode(secret));
}

P2pKeystore createKeystore() => NativeP2pKeystore();
