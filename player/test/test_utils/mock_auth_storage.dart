import 'package:player/core/auth/auth_storage.dart';

/// Manual mock implementation of [AuthStorage] for testing.
///
/// Uses an in-memory map to simulate storage operations.
class MockAuthStorage implements AuthStorage {
  final Map<String, String> _storage = {};

  /// Set by tests that need to simulate storage that cannot persist.
  bool degradedValue = false;

  @override
  bool get degraded => degradedValue;

  @override
  Future<String?> read(String key) async {
    return _storage[key];
  }

  @override
  Future<void> write(String key, String value) async {
    _storage[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _storage.remove(key);
  }

  @override
  Future<void> deleteAll() async {
    _storage.clear();
  }

  /// Seeds the storage with initial data for testing.
  void seedData(Map<String, String> data) {
    _storage.addAll(data);
  }

  /// Clears all stored data.
  void clear() {
    _storage.clear();
  }

  /// Returns a copy of the current storage contents.
  Map<String, String> get contents => Map.unmodifiable(_storage);

  /// Checks if a key exists in storage.
  bool containsKey(String key) => _storage.containsKey(key);
}
