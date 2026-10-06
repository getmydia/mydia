// No material.dart import here on purpose: it exports its own ConnectionState,
// which would clash with the app's.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/auth/auth_storage.dart';
// Only NativeAuthStorage is needed here: getAuthStorage() from
// auth_storage.dart would otherwise clash with the one this file also
// exports.
import 'package:player/core/auth/auth_storage_native.dart'
    show NativeAuthStorage;
import 'package:player/core/graphql/graphql_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    NativeAuthStorage.resetForTest();
  });

  test('logout forgets the pairing and signs out', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // The credential that matters most. It mints fresh access tokens through
    // an intentionally unauthenticated mutation, and the old logout left it in
    // place.
    final storage = getAuthStorage();
    await storage.write('pairing_device_token', 'device-tok');

    final notifier = container.read(authStateProvider.notifier);
    await notifier.login(
      serverUrl: 'https://mydia.local',
      token: 'tok',
      userId: 'u1',
      username: 'admin',
    );
    expect(container.read(authStateProvider).value, AuthStatus.authenticated);

    await notifier.logout();

    expect(await storage.read('pairing_device_token'), isNull);
    expect(container.read(authStateProvider).value, AuthStatus.unauthenticated);
    expect(await storage.read('auth_token'), isNull);
  });
}
