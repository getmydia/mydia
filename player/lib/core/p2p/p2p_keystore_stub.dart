import 'dart:typed_data';

import 'p2p_keystore.dart';

/// No-op for platforms with neither dart:io nor js_interop. Nothing is stored,
/// so `keypair_bytes` goes unset and the Rust core generates the identity.
class _NativeKeystore implements P2pKeystore {
  @override
  Future<Uint8List?> read() async => null;

  @override
  Future<void> write(Uint8List secret) async {}
}

P2pKeystore createKeystore() => _NativeKeystore();
