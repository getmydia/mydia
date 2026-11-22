import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/backup_gzip.dart';
import 'package:player/core/backup/vault_crypto.dart';

String hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final vk = List<int>.generate(32, (i) => i + 1);
  const vaultId = '0123456789abcdef0123456789abcdef';
  const slotId = '00112233aabbccdd';
  final plain = [1, 2, 3, 4, 5];

  Future<Uint8List> seal() => VaultCrypto.sealSlot(
    vaultKey: vk,
    vaultId: vaultId,
    epoch: 3,
    slotId: slotId,
    seq: 7,
    plaintext: plain,
  );

  Future<Uint8List> open(
    Uint8List sealed, {
    String vid = vaultId,
    int epoch = 3,
    String sid = slotId,
    int seq = 7,
  }) => VaultCrypto.openSlot(
    vaultKey: vk,
    vaultId: vid,
    epoch: epoch,
    slotId: sid,
    seq: seq,
    sealed: sealed,
  );

  group('slots', () {
    test('round trip and layout', () async {
      final sealed = await seal();
      expect(sealed.length, 24 + plain.length + 16);
      expect(await open(sealed), plain);
    });

    test('tampering or wrong context throws VaultCryptoException', () async {
      final sealed = await seal();
      final flipped = Uint8List.fromList(sealed)..[30] ^= 1;
      final bad = <Future<Uint8List> Function()>[
        () => open(flipped),
        () => open(sealed, epoch: 4),
        () => open(sealed, sid: '00112233aabbccde'),
        () => open(sealed, seq: 8),
        () => open(sealed, vid: 'ffffffffffffffffffffffffffffffff'),
        () => open(Uint8List(5)),
      ];
      for (final f in bad) {
        await expectLater(f(), throwsA(isA<VaultCryptoException>()));
      }
    });

    test('slotIdFor is 16 lowercase hex chars', () {
      final id = VaultCrypto.slotIdFor(List.filled(32, 9));
      expect(id, matches(RegExp(r'^[0-9a-f]{16}$')));
    });

    test('slotIdFor matches a pinned vector', () {
      // sha256(bytes([9]) * 32).hexdigest()[:16], computed with Python.
      expect(VaultCrypto.slotIdFor(List.filled(32, 9)), '8c0cc17a04942cc4');
    });
  });

  group('envelopes', () {
    test('round trip and length', () async {
      final box = await X25519().newKeyPair();
      final pub = await box.extractPublicKey();
      final env = await VaultCrypto.sealEnvelope(
        vaultKey: vk,
        recipientBox: pub,
        vaultId: vaultId,
        epoch: 3,
      );
      expect(env.length, 104);
      final out = await VaultCrypto.openEnvelope(
        box: box,
        envelope: env,
        vaultId: vaultId,
        epoch: 3,
      );
      expect(out, vk);
    });

    test('wrong key, wrong epoch or bad length throws', () async {
      final box = await X25519().newKeyPair();
      final other = await X25519().newKeyPair();
      final env = await VaultCrypto.sealEnvelope(
        vaultKey: vk,
        recipientBox: await box.extractPublicKey(),
        vaultId: vaultId,
        epoch: 3,
      );
      Future<Uint8List> o(SimpleKeyPair k, Uint8List e, int epoch) =>
          VaultCrypto.openEnvelope(
            box: k,
            envelope: e,
            vaultId: vaultId,
            epoch: epoch,
          );
      await expectLater(o(other, env, 3), throwsA(isA<VaultCryptoException>()));
      await expectLater(o(box, env, 4), throwsA(isA<VaultCryptoException>()));
      await expectLater(
        o(box, Uint8List.sublistView(env, 0, 103), 3),
        throwsA(isA<VaultCryptoException>()),
      );
    });

    // Inputs: shared secret 32 x 0x07, vault id above, epoch 3, empty salt.
    test('envelope key derivation vector', () async {
      final k = await VaultCrypto.envelopeKey(List.filled(32, 7), vaultId, 3);
      expect(
        hex(k),
        'f95de21e47425c09d80cd1c483678f29a4c6abcecc4da207da6610b62c5ee9b8',
      );
    });
  });

  test('gzip round trip', () {
    final data = List<int>.generate(1000, (i) => i % 7);
    expect(gzipDecode(gzipEncode(data)), data);
  });
}
