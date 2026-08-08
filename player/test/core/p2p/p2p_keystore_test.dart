// The stub is what native resolves to, so this only means anything off-browser.
// The IndexedDB implementation is covered by p2p_keystore_web_test.dart.
@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/p2p_keystore.dart';

void main() {
  group('P2pKeystore', () {
    test('stub returns null so native identity stays with the Rust core',
        () async {
      final keystore = createKeystore();
      expect(await keystore.read(), isNull);
    });

    test('stub write is a no-op and does not throw', () async {
      final keystore = createKeystore();
      await keystore.write(Uint8List.fromList(List.filled(32, 7)));
      expect(await keystore.read(), isNull);
    });
  });
}
