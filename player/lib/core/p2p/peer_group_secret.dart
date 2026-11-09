import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// The 32-byte shared secret of a paired device group.
///
/// Stored in `AuthStorage` under [storageKey] as unpadded base64url.
class PeerGroupSecret {
  PeerGroupSecret.fromBytes(Uint8List bytes)
      : _bytes = Uint8List.fromList(bytes) {
    if (_bytes.length != 32) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'PeerGroupSecret must be exactly 32 bytes',
      );
    }
  }

  factory PeerGroupSecret.generate([Random? random]) {
    final r = random ?? Random.secure();
    final bytes = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      bytes[i] = r.nextInt(256);
    }
    return PeerGroupSecret.fromBytes(bytes);
  }

  factory PeerGroupSecret.fromBase64Url(String encoded) {
    final normalized = base64.normalize(encoded);
    final bytes = base64Url.decode(normalized);
    return PeerGroupSecret.fromBytes(Uint8List.fromList(bytes));
  }

  static const storageKey = 'peer_group/secret';

  final Uint8List _bytes;

  Uint8List get bytes => Uint8List.fromList(_bytes);

  String toBase64Url() => base64Url.encode(_bytes).replaceAll('=', '');

  /// The first 16 lowercase hex characters of SHA-256("mydia/peer-group/id/v1" || bytes).
  String get groupId {
    final prefix = utf8.encode('mydia/peer-group/id/v1');
    final combined = Uint8List(prefix.length + _bytes.length);
    combined.setRange(0, prefix.length, prefix);
    combined.setRange(prefix.length, combined.length, _bytes);
    return sha256.convert(combined).toString().substring(0, 16).toLowerCase();
  }

  /// 64 lowercase hex characters of HMAC-SHA256(bytes, "mydia/peer-group/auth/v1|$senderNodeId").
  String authProof(String senderNodeId) {
    final hmac = Hmac(sha256, _bytes);
    final msg = utf8.encode('mydia/peer-group/auth/v1|$senderNodeId');
    return hmac.convert(msg).toString().toLowerCase();
  }

  /// Constant-time verification of an authentication proof.
  bool verifyAuthProof({required String senderNodeId, required String proof}) {
    final expected = authProof(senderNodeId);
    return _constantTimeStringEquals(expected, proof.toLowerCase());
  }

  static bool _constantTimeStringEquals(String a, String b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! PeerGroupSecret) return false;
    if (_bytes.length != other._bytes.length) return false;
    for (var i = 0; i < _bytes.length; i++) {
      if (_bytes[i] != other._bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var h = 0;
    for (final b in _bytes) {
      h = (h * 31 + b) & 0x3fffffff;
    }
    return h;
  }
}
