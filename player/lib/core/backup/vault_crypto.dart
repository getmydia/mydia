import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// Thrown by every open function when the input cannot be decrypted.
class VaultCryptoException implements Exception {
  const VaultCryptoException(this.message);
  final String message;

  @override
  String toString() => 'VaultCryptoException: $message';
}

const _nonceLength = 24;
const _macLength = 16;
const _keyLength = 32;
const _envelopeLength = 32 + _nonceLength + _keyLength + _macLength;

/// Pure slot and envelope crypto for the cloud backup vault.
abstract final class VaultCrypto {
  static final _aead = Xchacha20.poly1305Aead();

  static List<int> _slotAad(
          String vaultId, int epoch, String slotId, int seq) =>
      utf8.encode('mydia/backup/slot/v1|$vaultId|$epoch|$slotId|$seq');

  /// Returns `nonce(24) || ciphertext || mac(16)`.
  static Future<Uint8List> sealSlot({
    required List<int> vaultKey,
    required String vaultId,
    required int epoch,
    required String slotId,
    required int seq,
    required List<int> plaintext,
  }) async {
    final box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(vaultKey),
      aad: _slotAad(vaultId, epoch, slotId, seq),
    );
    return Uint8List.fromList(box.concatenation());
  }

  static Future<Uint8List> openSlot({
    required List<int> vaultKey,
    required String vaultId,
    required int epoch,
    required String slotId,
    required int seq,
    required List<int> sealed,
  }) =>
      _open(
        sealed,
        SecretKey(vaultKey),
        _slotAad(vaultId, epoch, slotId, seq),
        minLength: _nonceLength + _macLength,
      );

  static Future<Uint8List> _open(
    List<int> sealed,
    SecretKey key,
    List<int> aad, {
    required int minLength,
  }) async {
    if (sealed.length < minLength) {
      throw const VaultCryptoException('sealed data too short');
    }
    try {
      final box = SecretBox.fromConcatenation(
        sealed,
        nonceLength: _nonceLength,
        macLength: _macLength,
      );
      return Uint8List.fromList(
        await _aead.decrypt(box, secretKey: key, aad: aad),
      );
    } on VaultCryptoException {
      rethrow;
    } catch (e) {
      throw VaultCryptoException('decryption failed: ${e.runtimeType}');
    }
  }

  /// HKDF-SHA256 (empty salt) of an X25519 shared secret.
  @visibleForTesting
  static Future<Uint8List> envelopeKey(
    List<int> sharedSecret,
    String vaultId,
    int epoch,
  ) async {
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: SecretKey(sharedSecret),
      nonce: const <int>[],
      info: utf8.encode('mydia/backup/envelope/v1|$vaultId|$epoch'),
    );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// Returns `ephemeralPub(32) || nonce(24) || ciphertext(32) || mac(16)`.
  static Future<Uint8List> sealEnvelope({
    required List<int> vaultKey,
    required SimplePublicKey recipientBox,
    required String vaultId,
    required int epoch,
  }) async {
    final x = X25519();
    final ephemeral = await x.newKeyPair();
    final ephemeralPub = (await ephemeral.extractPublicKey()).bytes;
    final shared = await x.sharedSecretKey(
      keyPair: ephemeral,
      remotePublicKey: recipientBox,
    );
    final key = await envelopeKey(await shared.extractBytes(), vaultId, epoch);
    final box = await _aead.encrypt(
      vaultKey,
      secretKey: SecretKey(key),
      aad: ephemeralPub,
    );
    return Uint8List.fromList([...ephemeralPub, ...box.concatenation()]);
  }

  static Future<Uint8List> openEnvelope({
    required SimpleKeyPair box,
    required List<int> envelope,
    required String vaultId,
    required int epoch,
  }) async {
    if (envelope.length != _envelopeLength) {
      throw const VaultCryptoException('bad envelope length');
    }
    try {
      final ephemeralPub = envelope.sublist(0, 32);
      final shared = await X25519().sharedSecretKey(
        keyPair: box,
        remotePublicKey:
            SimplePublicKey(ephemeralPub, type: KeyPairType.x25519),
      );
      final key = await envelopeKey(
        await shared.extractBytes(),
        vaultId,
        epoch,
      );
      return await _open(
        envelope.sublist(32),
        SecretKey(key),
        ephemeralPub,
        minLength: _nonceLength + _macLength,
      );
    } on VaultCryptoException {
      rethrow;
    } catch (e) {
      throw VaultCryptoException('envelope open failed: ${e.runtimeType}');
    }
  }

  /// First 16 hex chars of SHA-256 of the signer public key.
  static String slotIdFor(List<int> signerPublicKey) {
    final digest = _sha256Sync(signerPublicKey);
    return digest
        .take(8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}

List<int> _sha256Sync(List<int> data) => Sha256().toSync().hashSync(data).bytes;
