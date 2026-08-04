import 'dart:io' show Platform;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:player/core/auth/auth_storage.dart';
import 'package:player/core/storage/secure_storage_options.dart';
import 'helpers/test_bootstrap.dart';

/// Regression tests for the "have to re-pair on every launch" bug.
///
/// Two defects combined to lose the user's pairing on every restart:
///
/// 1. The shipped macOS app carried no code-signing entitlements, and
///    `flutter_secure_storage` used the data-protection keychain, which needs
///    a keychain access group. Every call failed with
///    `errSecMissingEntitlement` (-34018).
/// 2. `AuthStorage` caught that and latched an in-memory fallback for the rest
///    of the process, so nothing ever surfaced and nothing ever persisted.
///
/// The first test talks to `FlutterSecureStorage` directly, bypassing
/// `AuthStorage` — a round trip through `AuthStorage` passes even with a
/// completely broken keychain, because the memory map satisfies it.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Set up the app once before all tests. Shared with the other integration
  // test files so all_tests.dart can run them in one process.
  setUpAll(ensureTestBootstrap);

  const raw = FlutterSecureStorage(
    aOptions: kAndroidSecureStorageOptions,
    mOptions: kMacOsSecureStorageOptions,
  );
  const key = 'secure_storage_regression_probe';

  Future<void> discard() async {
    try {
      await raw.delete(key: key);
    } catch (_) {
      // Deleting an absent key throws -34018 on the macOS legacy keychain.
    }
  }

  setUp(discard);
  tearDown(discard);

  // Skip on Linux only: needs a session dbus in the toolbox image for
  // libsecret. On Linux the real keychain fails every call with
  // PlatformException(KeyringLocked, KeyringLocked, null, null) because there
  // is no session bus running to unlock a libsecret provider
  // (gnome-keyring/kwallet). To enable, run dbus-launch (or a real session
  // bus) and a libsecret provider (gnome-keyring/kwallet) inside the
  // player-e2e-toolbox image. These are the regression tests for the macOS
  // re-pair bug, so they must still run on macOS.
  testWidgets(
    'the real keychain accepts writes and reads them back',
    (tester) async {
      // Before the fix this threw PlatformException(-34018) on macOS.
      await raw.write(key: key, value: 'persisted-value');

      expect(await raw.read(key: key), 'persisted-value');
    },
    skip: Platform.isLinux, // needs a session dbus for libsecret; see above
  );

  // Skip on Linux only: same libsecret/session-dbus gap as the test above.
  testWidgets(
    'a failing delete does not disable later persistence',
    (tester) async {
      final storage = getAuthStorage();

      // Deleting a key that isn't there fails on the macOS legacy keychain.
      // AuthStorage must absorb that without giving up on secure storage.
      await storage.delete(key);

      await storage.write(key, 'still-persisted');

      // Read through the raw plugin, not AuthStorage: if the write had been
      // downgraded to the in-memory map, AuthStorage would still return the
      // value but the keychain would be empty and the app would lose it on
      // exit.
      expect(await raw.read(key: key), 'still-persisted');
    },
    skip: Platform.isLinux, // needs a session dbus for libsecret; see above
  );
}
