import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../auth/auth_storage.dart';
import 'vault_crypto.dart';

/// This device's long-lived backup identity: an Ed25519 signer and an X25519
/// box key pair, persisted as seeds in [AuthStorage] under [storageKey].
class BackupIdentity {
  BackupIdentity._({
    required this.signer,
    required this.box,
    required this.slotId,
    required SimplePublicKey signerPublic,
    required SimplePublicKey boxPublic,
  })  : _signerPublic = signerPublic,
        _boxPublic = boxPublic;

  static const storageKey = 'backup/identity';

  final SimpleKeyPair signer;
  final SimpleKeyPair box;
  final String slotId;
  final SimplePublicKey _signerPublic;
  final SimplePublicKey _boxPublic;

  Future<String> signerPublicB64() async => _b64(_signerPublic.bytes);

  Future<String> boxPublicB64() async => _b64(_boxPublic.bytes);

  /// Loads the stored identity or creates and persists a new one.
  ///
  /// Throws [StateError] if stored data exists but is unreadable: replacing it
  /// would orphan this device's vault membership, so the caller decides.
  static Future<BackupIdentity> loadOrCreate(AuthStorage storage) async {
    final raw = await storage.read(storageKey);
    if (raw == null) {
      final signerSeed = _randomSeed();
      final boxSeed = _randomSeed();
      await storage.write(
        storageKey,
        jsonEncode({
          'v': 1,
          'signerSeed': _b64(signerSeed),
          'boxSeed': _b64(boxSeed),
        }),
      );
      if (storage.degraded) {
        throw StateError('backup identity not durable');
      }
      return _build(signerSeed, boxSeed);
    }
    final Uint8List signerSeed;
    final Uint8List boxSeed;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['v'] != 1) throw const FormatException('unsupported version');
      signerSeed = _decodeSeed(json['signerSeed']);
      boxSeed = _decodeSeed(json['boxSeed']);
    } on Object catch (e) {
      throw StateError('stored backup identity is unreadable: $e');
    }
    return _build(signerSeed, boxSeed);
  }

  static Future<BackupIdentity> _build(
    Uint8List signerSeed,
    Uint8List boxSeed,
  ) async {
    final signer = await Ed25519().newKeyPairFromSeed(signerSeed);
    final box = await X25519().newKeyPairFromSeed(boxSeed);
    final signerPub = await signer.extractPublicKey();
    final boxPub = await box.extractPublicKey();
    return BackupIdentity._(
      signer: signer,
      box: box,
      slotId: VaultCrypto.slotIdFor(signerPub.bytes),
      signerPublic: signerPub,
      boxPublic: boxPub,
    );
  }

  static Uint8List _randomSeed() {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)));
  }

  static Uint8List _decodeSeed(Object? value) {
    if (value is! String) throw const FormatException('missing seed');
    final bytes = base64Url.decode(base64.normalize(value));
    if (bytes.length != 32) {
      throw const FormatException('seed must be 32 bytes');
    }
    return Uint8List.fromList(bytes);
  }

  static String _b64(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');
}
