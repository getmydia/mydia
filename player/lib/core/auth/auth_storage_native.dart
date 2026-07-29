/// Native implementation using flutter_secure_storage.
///
/// This provides secure storage on iOS, Android, macOS, Windows, and Linux.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../storage/secure_storage_options.dart';
import 'auth_storage.dart';

AuthStorage getAuthStorage() => _NativeAuthStorage();

class _NativeAuthStorage implements AuthStorage {
  static const _storage = FlutterSecureStorage(
    aOptions: kAndroidSecureStorageOptions,
    mOptions: kMacOsSecureStorageOptions,
  );

  static final Map<String, String> _memoryStorage = <String, String>{};
  static bool _warnedAboutFallback = false;

  /// Runs [operation] against secure storage, degrading to an in-memory map
  /// only for the individual call that failed.
  ///
  /// This deliberately does NOT latch. A single failure used to disable secure
  /// storage for the whole process, so one bad call — for example deleting a
  /// key that isn't there, which `flutter_secure_storage` reports as -34018 on
  /// the macOS legacy keychain — silently downgraded every later read and
  /// write to memory and cost the user their pairing on the next launch.
  Future<T> _withFallback<T>(
      Future<T> Function() operation, T Function() onFallback) async {
    try {
      return await operation();
    } catch (e) {
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
      () => _storage.read(key: key),
      () => _memoryStorage[key],
    );
    // A prior write may have been the one call that failed and landed in
    // memory, so fall back to it rather than reporting the key as missing.
    return value ?? _memoryStorage[key];
  }

  @override
  Future<void> write(String key, String value) async {
    await _withFallback<void>(
      () => _storage.write(key: key, value: value),
      () {
        _memoryStorage[key] = value;
      },
    );
  }

  @override
  Future<void> delete(String key) async {
    await _withFallback<void>(
      () => _storage.delete(key: key),
      () {
        _memoryStorage.remove(key);
      },
    );
  }

  @override
  Future<void> deleteAll() async {
    await _withFallback<void>(
      _storage.deleteAll,
      () {
        _memoryStorage.clear();
      },
    );
  }
}
