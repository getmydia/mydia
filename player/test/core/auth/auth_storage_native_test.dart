import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_storage_native.dart';

/// A backend whose operations fail on demand, standing in for a keyring that
/// is absent, locked, or unreachable across D-Bus.
class _FailingBackend implements SecretBackend {
  _FailingBackend({
    this.failWrite = false,
    this.failDelete = false,
  });

  final bool failWrite;
  final bool failDelete;

  final Map<String, String> stored = {};

  @override
  Future<String?> read(String key) async {
    return stored[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw Exception('keyring unavailable');
    stored[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw Exception('keyring unavailable');
    stored.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    if (failDelete) throw Exception('keyring unavailable');
    stored.clear();
  }
}

void main() {
  group('NativeAuthStorage', () {
    setUp(NativeAuthStorage.resetForTest);
    tearDown(NativeAuthStorage.resetForTest);

    test('is not degraded when writes reach the backend', () async {
      final storage = NativeAuthStorage(backend: _FailingBackend());

      await storage.write('token', 'abc');

      expect(storage.degraded, isFalse);
      expect(await storage.read('token'), equals('abc'));
    });

    test('reports degraded when a write fails', () async {
      final storage =
          NativeAuthStorage(backend: _FailingBackend(failWrite: true));

      await storage.write('token', 'abc');

      expect(storage.degraded, isTrue);
    });

    test('keeps the value readable in-session after a failed write', () async {
      final storage =
          NativeAuthStorage(backend: _FailingBackend(failWrite: true));

      await storage.write('token', 'abc');

      // The session must keep working; only durability is lost.
      expect(await storage.read('token'), equals('abc'));
    });

    test('a failed write is not shadowed by an older backend value', () async {
      // The backend already holds a value the keyring accepted earlier.
      final backend = _FailingBackend(failWrite: true)
        ..stored['token'] = 'stale';
      final storage = NativeAuthStorage(backend: backend);

      await storage.write('token', 'fresh');

      // Reading must not prefer the backend here. A refreshed access token
      // that failed to persist would otherwise leave every later read handing
      // back the expired one for the rest of the session.
      expect(await storage.read('token'), equals('fresh'));
    });

    test('a successful write is not shadowed by an earlier fallback', () async {
      final storage = NativeAuthStorage(backend: _FailingBackend());

      await storage.write('token', 'first');
      await storage.write('token', 'second');

      expect(await storage.read('token'), equals('second'));
    });

    test('a delete clears the in-memory overlay', () async {
      final storage =
          NativeAuthStorage(backend: _FailingBackend(failWrite: true));

      await storage.write('token', 'abc');
      await storage.delete('token');

      // Without clearing the overlay, a deleted credential would keep being
      // served for the rest of the session.
      expect(await storage.read('token'), isNull);
    });

    test('a failed delete does not report degraded', () async {
      final storage =
          NativeAuthStorage(backend: _FailingBackend(failDelete: true));

      await storage.delete('missing-key');

      // Deleting an absent key is the benign macOS -34018 case that
      // secure_storage_options.dart documents. It must stay tolerated, and it
      // says nothing about whether writes are durable.
      expect(storage.degraded, isFalse);
    });

    test('degraded is sticky once a write has failed', () async {
      final backend = _FailingBackend(failWrite: true);
      final storage = NativeAuthStorage(backend: backend);

      await storage.write('token', 'abc');
      expect(storage.degraded, isTrue);

      // A later success does not prove the earlier lost write came back.
      final healthy = NativeAuthStorage(backend: _FailingBackend());
      await healthy.write('other', 'xyz');

      expect(healthy.degraded, isTrue);
    });
  });
}
