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
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/core/graphql/graphql_provider.dart';

/// A connection notifier whose clear() fails, standing in for any cleanup step
/// that throws part-way through sign-out.
class _ThrowingConnectionNotifier extends ConnectionNotifier {
  @override
  ConnectionState build() => const ConnectionState(type: ConnectionType.direct);

  @override
  Future<void> clear() async => throw Exception('keyring unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    NativeAuthStorage.resetForTest();
  });

  test('logout forgets the pairing, even when a cleanup step throws', () async {
    final container = ProviderContainer(overrides: [
      connectionProvider.overrideWith(_ThrowingConnectionNotifier.new),
    ]);
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
    // And the throwing connection step did not prevent the sign-out itself.
    expect(container.read(authStateProvider).value, AuthStatus.unauthenticated);
    expect(await storage.read('auth_token'), isNull);
  });
}
