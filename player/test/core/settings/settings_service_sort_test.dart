import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:player/core/auth/auth_storage_native.dart';
import 'package:player/core/settings/settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    NativeAuthStorage.resetForTest();
  });

  test('an unset library sort reads back as null', () async {
    final service = SettingsService();

    expect(await service.getLibrarySort('movies'), isNull);
  });

  test('a stored sort round-trips', () async {
    final service = SettingsService();

    await service.setLibrarySort('movies', 'RATING:DESC');

    expect(await service.getLibrarySort('movies'), 'RATING:DESC');
  });

  test('movies and tv shows are remembered independently', () async {
    final service = SettingsService();

    await service.setLibrarySort('movies', 'RUNTIME:ASC');
    await service.setLibrarySort('tvShows', 'LAST_PLAYED:DESC');

    expect(await service.getLibrarySort('movies'), 'RUNTIME:ASC');
    expect(await service.getLibrarySort('tvShows'), 'LAST_PLAYED:DESC');
  });

  test('clearSettings drops both library sorts', () async {
    final service = SettingsService();
    await service.setLibrarySort('movies', 'YEAR:ASC');

    await service.clearSettings();

    expect(await service.getLibrarySort('movies'), isNull);
  });
}
