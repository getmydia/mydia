import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_keystore.dart';
import 'package:player/core/p2p/p2p_service.dart';

/// A keystore whose reads finish when the test says so, so two loads can be
/// held open at the same time, the way a reset() during startup holds them.
class _GatedKeystore implements P2pKeystore {
  final gate = Completer<void>();
  Uint8List? stored;
  int reads = 0;
  int writes = 0;
  Exception? failNextRead;

  @override
  Future<Uint8List?> read() async {
    reads++;
    final failure = failNextRead;
    failNextRead = null;
    await gate.future;
    if (failure != null) throw failure;
    return stored;
  }

  @override
  Future<void> write(Uint8List secret) async {
    writes++;
    stored = secret;
  }
}

void main() {
  late _GatedKeystore keystore;

  setUp(() {
    keystore = _GatedKeystore();
    P2pService.debugResetNodeSecret(keystore: () => keystore);
  });

  tearDown(P2pService.debugResetNodeSecret);

  group('P2pService node secret', () {
    test('concurrent first-run loads share one secret and one write', () async {
      final first = P2pService.debugLoadOrCreateKeypairBytes();
      final second = P2pService.debugLoadOrCreateKeypairBytes();

      keystore.gate.complete();
      final secrets = await Future.wait([first, second]);

      expect(secrets[0], isNotNull);
      expect(secrets[1], same(secrets[0]));
      expect(keystore.reads, 1);
      expect(keystore.writes, 1);
      expect(keystore.stored, same(secrets[0]),
          reason: 'the keystore must hold the secret the host starts with');
    });

    test('a later load reuses the finished one', () async {
      keystore.gate.complete();
      final first = await P2pService.debugLoadOrCreateKeypairBytes();
      final second = await P2pService.debugLoadOrCreateKeypairBytes();

      expect(second, same(first));
      expect(keystore.reads, 1);
      expect(keystore.writes, 1);
    });

    test('a failed load is forgotten so the next one retries', () async {
      keystore.failNextRead = Exception('keyring locked');
      final failed = P2pService.debugLoadOrCreateKeypairBytes();
      keystore.gate.complete();
      await expectLater(failed, throwsException);

      final secret = await P2pService.debugLoadOrCreateKeypairBytes();

      expect(secret, isNotNull);
      expect(keystore.reads, 2);
      expect(keystore.writes, 1);
    });
  });
}
