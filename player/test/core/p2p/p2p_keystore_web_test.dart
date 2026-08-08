// Runs only under `flutter test --platform chrome`; there is no IndexedDB in
// the VM test runner. A VM run skips this file rather than failing it.
@TestOn('browser')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_keystore.dart';

void main() {
  group('P2pKeystore on web', () {
    test('reads back the secret a separate instance wrote', () async {
      final secret = Uint8List.fromList(List.generate(32, (i) => i * 7 % 256));

      await createKeystore().write(secret);

      // A fresh instance, because the browser reopens the database on every
      // load and reading null there would be read as a first run and cost the
      // node its identity.
      expect(await createKeystore().read(), equals(secret));
    });

    test('the last write wins', () async {
      final first = Uint8List.fromList(List.filled(32, 1));
      final second = Uint8List.fromList(List.filled(32, 2));

      final keystore = createKeystore();
      await keystore.write(first);
      await keystore.write(second);

      expect(await keystore.read(), equals(second));
    });
  });
}
