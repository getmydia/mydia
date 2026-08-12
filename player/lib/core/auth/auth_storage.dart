/// Abstract interface for auth storage.
///
/// This allows different implementations for web and native platforms.
library;

import 'auth_storage_stub.dart'
    if (dart.library.html) 'auth_storage_web.dart'
    if (dart.library.io) 'auth_storage_native.dart' as impl;

/// Get the platform-appropriate auth storage implementation.
AuthStorage getAuthStorage() => impl.getAuthStorage();

/// Abstract interface for storing authentication data.
abstract class AuthStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> deleteAll();

  /// Whether any write has failed to reach durable storage in this process.
  ///
  /// A caller that has just written credentials should check this before
  /// telling the user the credentials were saved.
  bool get degraded;
}
