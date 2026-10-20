@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_storage_native.dart';
import 'package:player/core/p2p/p2p_keystore_native.dart';

class _MapBackend implements SecretBackend {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<void> deleteAll() async => values.clear();
}

class _BrokenBackend extends _MapBackend {
  @override
  Future<String?> read(String key) async => throw Exception('keyring locked');
}

void main() {
  group('NativeP2pKeystore', () {
    test('reads null before anything is stored', () async {
      expect(await NativeP2pKeystore(backend: _MapBackend()).read(), isNull);
    });

    test('round-trips the 32-byte secret', () async {
      final backend = _MapBackend();
      final secret = Uint8List.fromList(List.generate(32, (i) => i));
      await NativeP2pKeystore(backend: backend).write(secret);
      expect(await NativeP2pKeystore(backend: backend).read(), secret);
    });

    test('a backend failure throws instead of reading as absent', () async {
      await expectLater(
          NativeP2pKeystore(backend: _BrokenBackend()).read(), throwsException);
    });

    test('a stored value that is not 32 bytes throws', () async {
      final backend = _MapBackend()..values['p2p_node_secret'] = 'AAAA';
      await expectLater(
          NativeP2pKeystore(backend: backend).read(), throwsA(anything));
    });
  });
}
