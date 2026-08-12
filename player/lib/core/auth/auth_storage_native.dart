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
    final value = await _withFallback<String?>(
      () => _backend.read(key),
      () => _memoryStorage[key],
    );
    // A prior write may have been the one call that failed and landed in
    // memory, so fall back to it rather than reporting the key as missing.
    return value ?? _memoryStorage[key];
  }

  @override
  Future<void> write(String key, String value) async {
    await _withFallback<void>(
      () => _backend.write(key, value),
      () {
        _memoryStorage[key] = value;
      },
      durability: true,
    );
  }

  @override
  Future<void> delete(String key) async {
    await _withFallback<void>(
      () => _backend.delete(key),
      () {
        _memoryStorage.remove(key);
      },
    );
  }

  @override
  Future<void> deleteAll() async {
    await _withFallback<void>(
      _backend.deleteAll,
      () {
        _memoryStorage.clear();
      },
    );
  }
}
