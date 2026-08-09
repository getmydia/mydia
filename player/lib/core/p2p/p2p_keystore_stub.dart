import 'dart:typed_data';

import 'p2p_keystore.dart';

/// Native no-op. The Rust core owns the identity on these platforms, so there
/// is nothing here to store or hand back.
class _NativeKeystore implements P2pKeystore {
  @override
  Future<Uint8List?> read() async => null;

  @override
  Future<void> write(Uint8List secret) async {}
}

P2pKeystore createKeystore() => _NativeKeystore();
