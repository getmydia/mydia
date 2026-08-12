/// Web implementation using localStorage.
///
/// On web, we use localStorage for persistence. Note that this is less
/// secure than flutter_secure_storage on native platforms, but for web
/// this is the standard approach.
library;

import 'package:web/web.dart' as web;

import 'auth_storage.dart';

AuthStorage getAuthStorage() => _WebAuthStorage();

class _WebAuthStorage implements AuthStorage {
  static const _prefix = 'mydia_auth_';

  /// localStorage writes do not go through a fallback path, so there is no
  /// degraded state to report on web.
  @override
  bool get degraded => false;

  @override
  Future<String?> read(String key) async {
    final value = web.window.localStorage.getItem('$_prefix$key');
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    web.window.localStorage.setItem('$_prefix$key', value);
  }

  @override
  Future<void> delete(String key) async {
    web.window.localStorage.removeItem('$_prefix$key');
  }

  @override
  Future<void> deleteAll() async {
    // Remove all keys with our prefix
    final keysToRemove = <String>[];
    final storage = web.window.localStorage;
    final length = storage.length;

    for (var i = 0; i < length; i++) {
      final key = storage.key(i);
      if (key != null && key.startsWith(_prefix)) {
        keysToRemove.add(key);
      }
    }

    for (final key in keysToRemove) {
      storage.removeItem(key);
    }
  }
}
