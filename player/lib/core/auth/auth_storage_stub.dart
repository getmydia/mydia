/// Stub implementation - should not be used directly.
///
/// This file exists to satisfy the conditional import when neither
/// dart:html nor dart:io is available (which shouldn't happen in practice).
library;

import 'auth_storage.dart';

AuthStorage getAuthStorage() => _StubAuthStorage();

class _StubAuthStorage implements AuthStorage {
  final Map<String, String> _data = {};

  @override
  bool get degraded => false;

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    _data.clear();
  }
}
