/// Native implementation using flutter_secure_storage.
///
/// This provides secure storage on iOS, Android, macOS, Windows, and Linux.
library;

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../storage/secure_storage_options.dart';
import 'auth_storage.dart';

AuthStorage getAuthStorage() => NativeAuthStorage();

/// The subset of `FlutterSecureStorage` this file depends on.
///
/// Exists so a test can inject a backend that fails. The degraded path only
/// runs when the platform keyring is unavailable, and there is no other way to
/// reach it in a unit test without a genuinely broken keyring.
abstract class SecretBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> deleteAll();
}

class _FlutterSecureStorageBackend implements SecretBackend {
  const _FlutterSecureStorageBackend();

  static const _storage = FlutterSecureStorage(
    aOptions: kAndroidSecureStorageOptions,
    mOptions: kMacOsSecureStorageOptions,
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> deleteAll() => _storage.deleteAll();
}

class NativeAuthStorage implements AuthStorage {
  NativeAuthStorage({SecretBackend? backend})
      : _backend = backend ?? const _FlutterSecureStorageBackend();

  final SecretBackend _backend;

  static final Map<String, String> _memoryStorage = <String, String>{};
  static bool _warnedAboutFallback = false;
  static bool _degraded = false;

  /// Backend answers already fetched this process, including "absent" (null).
  ///
  /// Keychain and keystore reads are slow on some platforms, and startup used
  /// to read the same token and server URL two or three times each through
  /// separate providers. Static for the same reason [_memoryStorage] is:
  /// `PairingService`, `SessionTeardown` and `AuthService` each hold their own
  /// instance, and they must all see each other's writes.
  static final Map<String, String?> _readCache = <String, String?>{};

  /// Backend reads in flight, so concurrent reads of one key share a call.
  static final Map<String, Future<String?>> _inflight =
      <String, Future<String?>>{};

  /// Bumped by every write, delete, and deleteAll.
  ///
  /// A read that was still in flight when one of those landed captures the
  /// generation before calling the backend; if it has moved on by the time
  /// the backend answers, that answer is stale and must not be written into
  /// [_readCache]. `deleteAll` in particular clears [_readCache] outright, so
  /// a plain "is the key still absent from the cache" check would let a
  /// stale in-flight answer repopulate it as if the key had never been
  /// deleted. The generation check catches that even though the key is gone
  /// from the map, not just tombstoned in it.
  static int _generation = 0;

  /// Whether any write has failed to reach the platform keyring in this
  /// process.
  ///
  /// Sticky, and deliberately never cleared. This failure is a property of the
  /// environment rather than a transient fault, and once a write has been lost
  /// there is no way to know what else went with it. Process lifetime bounds
  /// how long the flag can be wrong.
  @override
  bool get degraded => _degraded;

  /// Resets the process-wide state so one test cannot leak into the next.
  @visibleForTesting
  static void resetForTest() {
    _memoryStorage.clear();
    _warnedAboutFallback = false;
    _degraded = false;
    _readCache.clear();
    _inflight.clear();
    _generation = 0;
  }

  /// Runs [operation] against secure storage, degrading to an in-memory map
  /// only for the individual call that failed.
  ///
  /// This deliberately does NOT latch. A single failure used to disable secure
  /// storage for the whole process, so one bad call — for example deleting a
  /// key that isn't there, which `flutter_secure_storage` reports as -34018 on
  /// the macOS legacy keychain — silently downgraded every later read and
  /// write to memory and cost the user their pairing on the next launch.
  ///
  /// [durability] marks the calls whose failure means data will not survive
  /// the process. Only those set [degraded]; a failed delete does not.
  Future<T> _withFallback<T>(
    Future<T> Function() operation,
    T Function() onFallback, {
    bool durability = false,
  }) async {
    try {
      return await operation();
    } catch (e) {
      if (durability) _degraded = true;
      if (!_warnedAboutFallback) {
        _warnedAboutFallback = true;
        debugPrint(
          '[AuthStorage] Secure storage call failed; using in-memory storage '
          'for this operation. If this repeats for writes, credentials will '
          'not survive an app restart. Cause: $e',
        );
      }
      return onFallback();
    }
  }

  @override
  Future<String?> read(String key) async {
    // The overlay wins whenever it holds the key. Consulting the backend first
    // would return whatever it still has from an earlier successful write,
    // which is older than a write that has since fallen back to memory. That
    // is how a failed token refresh would keep handing out the expired token
    // for the rest of the session.
    if (_memoryStorage.containsKey(key)) return _memoryStorage[key];
    if (_readCache.containsKey(key)) return _readCache[key];

    return _inflight[key] ??= _readBackend(key).whenComplete(() {
      _inflight.remove(key);
    });
  }

  /// Caches only a read the backend actually answered. A failed read falls
  /// back to null for this call, as before, and the next read tries again.
  /// Skips the cache write if a write, delete, or deleteAll landed while it
  /// was in flight: the overlay, the cached null from `delete`, or the
  /// cleared cache from `deleteAll` is newer than this backend answer, which
  /// [_generation] having moved on reveals.
  Future<String?> _readBackend(String key) async {
    final generation = _generation;
    var answered = false;
    final value = await _withFallback<String?>(() async {
      final v = await _backend.read(key);
      answered = true;
      return v;
    }, () => null);
    if (answered &&
        generation == _generation &&
        !_memoryStorage.containsKey(key)) {
      _readCache[key] = value;
    }
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    // Mirrored unconditionally, not just on failure, so the overlay is never
    // staler than the backend. A write-on-failure-only overlay would let an
    // old fallback value shadow a later successful write.
    _memoryStorage[key] = value;
    _generation++;

    await _withFallback<void>(
      () => _backend.write(key, value),
      () {},
      durability: true,
    );
  }

  @override
  Future<void> delete(String key) async {
    _memoryStorage.remove(key);
    _readCache[key] = null;
    _generation++;

    await _withFallback<void>(() => _backend.delete(key), () {});
  }

  @override
  Future<void> deleteAll() async {
    _memoryStorage.clear();
    _readCache.clear();
    _generation++;

    await _withFallback<void>(_backend.deleteAll, () {});
  }
}
