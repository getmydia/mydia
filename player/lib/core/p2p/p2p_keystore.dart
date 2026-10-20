import 'dart:typed_data';

import 'p2p_keystore_stub.dart'
    if (dart.library.io) 'p2p_keystore_native.dart'
    if (dart.library.js_interop) 'p2p_keystore_web.dart' as impl;

/// Persistence for the node's Ed25519 secret key.
///
/// Native platforms store the secret in the platform keyring. A browser has
/// no filesystem, so the web implementation stores the raw 32 bytes in
/// IndexedDB. Either way they are handed to `HostConfig.keypair_bytes`. The
/// stub keeps no identity and remains only for platforms with neither.
abstract class P2pKeystore {
  /// The stored secret, or null when nothing has been stored yet.
  ///
  /// This must never report null for a secret that actually exists: the caller
  /// reads that as a first run and generates a new identity, which orphans
  /// every pairing the old identity held. Failures throw rather than degrade
  /// into a silent null.
  Future<Uint8List?> read();

  Future<void> write(Uint8List secret);
}

P2pKeystore createKeystore() => impl.createKeystore();
