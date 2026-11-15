import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/backup/recovery_key.dart';

String hex(List<int> b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  const vectorText = '000G40R40M30E209185GR38E1W8124GK2GAHC5RR34D1P70X3RFG';

  group('RecoveryKey', () {
    test('generate then parse(display) round trips', () {
      final key = RecoveryKey.generate();
      expect(key.bytes.length, 32);
      expect(RecoveryKey.parse(key.display).bytes, key.bytes);
    });

    test('display is 13 groups of 4', () {
      final groups = RecoveryKey.generate().display.split(' ');
      expect(groups.length, 13);
      expect(groups.every((g) => g.length == 4), isTrue);
    });

    test('parse ignores case, spaces, dashes and maps O, I, L', () {
      final key = RecoveryKey.parse(vectorText);
      expect(key.bytes, Uint8List.fromList(List.generate(32, (i) => i)));
      const messy = '000g-4oR4 0m30E2o9l85GR38EIW8l24GK2GAHC5RR34D1P70X3RFG';
      expect(RecoveryKey.parse(messy).bytes, key.bytes);
    });

    test('parse rejects wrong length, bad alphabet and non-zero padding', () {
      expect(
        () => RecoveryKey.parse(vectorText.substring(1)),
        throwsFormatException,
      );
      expect(() => RecoveryKey.parse('${vectorText}0'), throwsFormatException);
      expect(
        () => RecoveryKey.parse('U${vectorText.substring(1)}'),
        throwsFormatException,
      );
      // The final char carries 1 data bit; 1 (0b00001) sets padding bits.
      expect(
        () => RecoveryKey.parse('${vectorText.substring(0, 51)}1'),
        throwsFormatException,
      );
    });

    // Inputs: key bytes 0x00..0x1f, empty HKDF salt, infos from the spec.
    test('fixed vector', () async {
      final key = RecoveryKey.parse(vectorText);
      final signer = await key.signer();
      final box = await key.boxKey();
      expect(
        hex((await signer.extractPublicKey()).bytes),
        '11213eb2c889b6ddf2e21e613354d3b0224ca590649fddc2a8178153ce3736a5',
      );
      expect(
        hex((await box.extractPublicKey()).bytes),
        '2be1d608e2ed06160afc4543217a6dc903d116aa0f532ee05d3d0138fd6cf732',
      );
      expect(
        hex(await key.lookupHandle()),
        'd0abd402eaf1e2a6b5e2827ad554d300e816377946523801516ddbdd5859cae3',
      );
    });
  });
}
