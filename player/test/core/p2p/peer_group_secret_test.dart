import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/peer_group_secret.dart';

void main() {
  group('PeerGroupSecret', () {
    test('generates_32_bytes_and_round_trips_base64url', () {
      final secret = PeerGroupSecret.generate();
      expect(secret.bytes.length, 32);

      final encoded = secret.toBase64Url();
      expect(encoded.contains('='), isFalse);
      expect(encoded.contains('+'), isFalse);
      expect(encoded.contains('/'), isFalse);

      final decoded = PeerGroupSecret.fromBase64Url(encoded);
      expect(decoded.bytes, equals(secret.bytes));
      expect(decoded.groupId, equals(secret.groupId));
    });

    test('derives_deterministic_16_char_hex_group_id', () {
      final bytes = Uint8List.fromList(List.generate(32, (i) => i));
      final secret1 = PeerGroupSecret.fromBytes(bytes);
      final secret2 = PeerGroupSecret.fromBytes(bytes);

      expect(secret1.groupId.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(secret1.groupId), isTrue);
      expect(secret1.groupId, equals(secret2.groupId));

      final otherBytes = Uint8List(32);
      final otherSecret = PeerGroupSecret.fromBytes(otherBytes);
      expect(otherSecret.groupId, isNot(equals(secret1.groupId)));
    });

    test('verifies_valid_auth_proof_and_rejects_wrong_node_or_tampered_proof',
        () {
      final secret = PeerGroupSecret.generate();
      const nodeId1 = 'node-echo-123';
      const nodeId2 = 'node-whisper-456';

      final proof = secret.authProof(nodeId1);
      expect(proof.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(proof), isTrue);

      expect(
        secret.verifyAuthProof(senderNodeId: nodeId1, proof: proof),
        isTrue,
      );

      expect(
        secret.verifyAuthProof(senderNodeId: nodeId2, proof: proof),
        isFalse,
      );

      final tamperedChar = proof[0] == 'a' ? 'b' : 'a';
      final tamperedProof = '$tamperedChar${proof.substring(1)}';
      expect(
        secret.verifyAuthProof(senderNodeId: nodeId1, proof: tamperedProof),
        isFalse,
      );

      expect(
        secret.verifyAuthProof(
          senderNodeId: nodeId1,
          proof: proof.substring(0, 32),
        ),
        isFalse,
      );
    });

    test('validates 32 byte length', () {
      expect(
        () => PeerGroupSecret.fromBytes(Uint8List(31)),
        throwsArgumentError,
      );
      expect(
        () => PeerGroupSecret.fromBytes(Uint8List(33)),
        throwsArgumentError,
      );
    });
  });
}
