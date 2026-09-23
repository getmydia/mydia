import 'dart:async';

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

class _CountingBackend implements SecretBackend {
  _CountingBackend(Map<String, String> initial) : _data = {...initial};
  final Map<String, String> _data;
  final Map<String, int> reads = {};
  bool failNextRead = false;

  @override
  Future<String?> read(String key) async {
    reads[key] = (reads[key] ?? 0) + 1;
    if (failNextRead) {
      failNextRead = false;
      throw StateError('keychain locked');
    }
    return _data[key];
  }

  @override
  Future<void> write(String key, String value) async => _data[key] = value;

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<void> deleteAll() async => _data.clear();
}

/// A backend whose `read` hangs until the test completes [pending], so a
/// test can land a delete while that read is still in flight.
class _BlockingBackend implements SecretBackend {
  _BlockingBackend(this.pending);
  final Completer<String?> pending;
  int readCount = 0;

  @override
  Future<String?> read(String key) async {
    readCount++;
    return pending.future;
  }

  @override
  Future<void> write(String key, String value) async {}

  @override
  Future<void> delete(String key) async {}

  @override
  Future<void> deleteAll() async {}
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

  group('read cache', () {
    setUp(NativeAuthStorage.resetForTest);
    tearDown(NativeAuthStorage.resetForTest);

    test('repeated and concurrent reads reach the backend once', () async {
      final backend = _CountingBackend({'auth_token': 't1'});
      final storage = NativeAuthStorage(backend: backend);

      final results = await Future.wait(
          [storage.read('auth_token'), storage.read('auth_token')]);
      await storage.read('auth_token');

      expect(results, ['t1', 't1']);
      expect(backend.reads['auth_token'], 1);
    });

    test('an absent key is cached as absent', () async {
      final backend = _CountingBackend({});
      final storage = NativeAuthStorage(backend: backend);
      expect(await storage.read('server_url'), isNull);
      expect(await storage.read('server_url'), isNull);
      expect(backend.reads['server_url'], 1);
    });

    test('a delete is seen by the next read without a backend hit', () async {
      final backend = _CountingBackend({'auth_token': 't1'});
      final storage = NativeAuthStorage(backend: backend);
      await storage.read('auth_token');
      await storage.delete('auth_token');
      expect(await storage.read('auth_token'), isNull);
      expect(backend.reads['auth_token'], 1);
    });

    test('a write is seen by a separate instance', () async {
      final backend = _CountingBackend({'auth_token': 'old'});
      await NativeAuthStorage(backend: backend).read('auth_token');
      await NativeAuthStorage(backend: backend).write('auth_token', 'new');
      expect(
          await NativeAuthStorage(backend: backend).read('auth_token'), 'new');
    });

    test('deleteAll drops the cache', () async {
      final backend = _CountingBackend({'auth_token': 't1'});
      final storage = NativeAuthStorage(backend: backend);
      await storage.read('auth_token');
      await storage.deleteAll();
      expect(await storage.read('auth_token'), isNull);
    });

    test('a failed read is not cached', () async {
      final backend = _CountingBackend({'auth_token': 't1'})
        ..failNextRead = true;
      final storage = NativeAuthStorage(backend: backend);
      expect(await storage.read('auth_token'), isNull);
      expect(await storage.read('auth_token'), 't1');
    });

    test(
        'a delete that lands while a read is in flight is not overwritten '
        'by that read', () async {
      final pending = Completer<String?>();
      final backend = _BlockingBackend(pending);
      final storage = NativeAuthStorage(backend: backend);

      // The read reaches the backend synchronously and then suspends on
      // `pending`, so by the time this line returns the backend has already
      // been called once.
      final firstRead = storage.read('auth_token');

      await storage.delete('auth_token');
      pending.complete('t1');

      // The in-flight call still resolves with what the backend answered...
      expect(await firstRead, 't1');
      // ...but the delete that landed while it was in flight wins the cache,
      // so the next read must see the deletion without hitting the backend
      // again.
      expect(await storage.read('auth_token'), isNull);
      expect(backend.readCount, 1);
    });
  });
}
