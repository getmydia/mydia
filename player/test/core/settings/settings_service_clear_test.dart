import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_storage_native.dart';
import 'package:player/core/settings/settings_service.dart';

import '../../test_utils/mock_auth_storage.dart';

/// A keychain that refuses every call, the way the macOS legacy keychain
/// refuses a delete for a key that was never written.
class _FailingBackend implements SecretBackend {
  @override
  Future<String?> read(String key) async =>
      throw Exception('keyring unavailable');

  @override
  Future<void> write(String key, String value) async =>
      throw Exception('keyring unavailable');

  @override
  Future<void> delete(String key) async =>
      throw Exception('keyring unavailable');

  @override
  Future<void> deleteAll() async => throw Exception('keyring unavailable');
}

void main() {
  setUp(NativeAuthStorage.resetForTest);

  test('clearSettings removes every settings key', () async {
    final storage = MockAuthStorage();
    final service = SettingsService(storage: storage);

    await service.setDefaultQuality('1080p');
    await service.setAutoSkipSegments(true);
    await service.setLibrarySort('movies', 'YEAR:ASC');
    await service.setLibrarySort('tvShows', 'RATING:DESC');

    await service.clearSettings();

    expect(storage.contents, isEmpty);
  });

  test('clearSettings completes when the keychain refuses every delete',
      () async {
    // The macOS sign-out bug. SettingsService talked to FlutterSecureStorage
    // directly, so a refused delete threw and aborted sign-out before it
    // reached the step that ends the session.
    final service = SettingsService(
      storage: NativeAuthStorage(backend: _FailingBackend()),
    );

    await expectLater(service.clearSettings(), completes);
  });
}
