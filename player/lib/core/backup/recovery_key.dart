import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const _keyLength = 32;
const _textLength = 52;

/// A 32 byte recovery secret with a single canonical Crockford base32 text
/// form (52 chars, no checksum, shown in groups of four).
class RecoveryKey {
  RecoveryKey._(this.bytes);

  /// Wraps raw key bytes. Throws [ArgumentError] unless there are 32.
  factory RecoveryKey.fromBytes(List<int> bytes) {
    if (bytes.length != _keyLength) {
      throw ArgumentError('recovery key must be $_keyLength bytes');
    }
    return RecoveryKey._(Uint8List.fromList(bytes));
  }

  factory RecoveryKey.generate() {
    final random = Random.secure();
    return RecoveryKey._(
      Uint8List.fromList(List.generate(_keyLength, (_) => random.nextInt(256))),
    );
  }

  /// Parses the text form. Ignores spaces, dashes and case, maps O to 0 and
  /// I/L to 1. Throws [FormatException] on a bad length, character or
  /// non-zero padding bits.
  factory RecoveryKey.parse(String text) {
    final chars = text
        .toUpperCase()
        .replaceAll(RegExp(r'[\s-]'), '')
        .replaceAll('O', '0')
        .replaceAll('I', '1')
        .replaceAll('L', '1');
    if (chars.length != _textLength) {
      throw const FormatException('recovery key must be 52 characters');
    }
    final out = Uint8List(_keyLength);
    var acc = 0;
    var bits = 0;
    var index = 0;
    for (final c in chars.split('')) {
      final v = _alphabet.indexOf(c);
      if (v < 0) {
        throw FormatException('invalid recovery key character: $c');
      }
      acc = (acc << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        if (index < _keyLength) out[index++] = (acc >> bits) & 0xff;
        acc &= (1 << bits) - 1;
      }
    }
    if (acc != 0) {
      throw const FormatException('invalid recovery key padding');
    }
    return RecoveryKey._(out);
  }

  final Uint8List bytes;

  String get display {
    final sb = StringBuffer();
    var acc = 0;
    var bits = 0;
    for (final b in bytes) {
      acc = (acc << 8) | b;
      bits += 8;
      while (bits >= 5) {
        bits -= 5;
        sb.write(_alphabet[(acc >> bits) & 31]);
      }
      acc &= (1 << bits) - 1;
    }
    if (bits > 0) sb.write(_alphabet[(acc << (5 - bits)) & 31]);
    final text = sb.toString();
    return [
      for (var i = 0; i < text.length; i += 4) text.substring(i, i + 4),
    ].join(' ');
  }

  Future<Uint8List> _derive(String info) async {
    final key = await Hkdf(
      hmac: Hmac.sha256(),
      outputLength: 32,
    ).deriveKey(
      secretKey: SecretKey(bytes),
      nonce: const <int>[],
      info: utf8.encode(info),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  Future<SimpleKeyPair> signer() async => Ed25519().newKeyPairFromSeed(
        await _derive('mydia/backup/recovery-signer/v1'),
      );

  Future<SimpleKeyPair> boxKey() async => X25519().newKeyPairFromSeed(
        await _derive('mydia/backup/recovery-box/v1'),
      );

  Future<Uint8List> lookupHandle() => _derive('mydia/backup/lookup/v1');
}
