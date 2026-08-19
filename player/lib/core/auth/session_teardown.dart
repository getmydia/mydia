import 'package:flutter/foundation.dart' show debugPrint;

import '../channels/pairing_service.dart';
import '../settings/settings_service.dart';
import 'auth_service.dart';
import 'auth_storage.dart';
import 'cert_storage.dart';

/// How long a single cleanup step may take before it is abandoned.
///
/// The macOS keychain can block on an access prompt that nobody is there to
/// answer. Without a ceiling, that prompt keeps the user signed in.
const _stepTimeout = Duration(seconds: 5);

/// Runs [step], swallowing failure and refusing to wait forever.
///
/// Sign-out has to finish even when storage is uncooperative, so a step that
/// throws or hangs is logged and skipped. The alternative is leaving the user
/// signed in, which is the bug this exists to prevent.
Future<void> bestEffort(
  String label,
  Future<void> Function() step, {
  Duration timeout = _stepTimeout,
}) async {
  try {
    await step().timeout(timeout);
  } catch (e) {
    debugPrint('[SessionTeardown] $label cleanup failed: $e');
  }
}

/// Erases every credential this device holds for the server it was signed into.
///
/// Deliberately leaves `device_id` alone. That is this installation's stable
/// identity, and regenerating it makes the next pairing create a second device
/// row on the server and orphan the first. It is also why this wipes an
/// explicit key list rather than calling [AuthStorage.deleteAll].
class SessionTeardown {
  /// [storage] is injectable for tests. Production callers use the default,
  /// which is the platform-appropriate implementation.
  SessionTeardown({AuthStorage? storage})
      : _storage = storage ?? getAuthStorage();

  final AuthStorage _storage;

  /// Wipes the session, the pairing, the pinned certificates and the settings.
  ///
  /// Steps are independent. The session goes first because it is the wipe that
  /// matters most, so it lands before anything else can misbehave.
  Future<void> run() async {
    final auth = AuthService(storage: _storage);

    await bestEffort('session', auth.clearSession);
    await bestEffort('relay url', auth.clearRelayUrl);
    await bestEffort(
      'pairing',
      PairingService(authStorage: _storage).clearCredentials,
    );
    await bestEffort('certs', CertStorage(storage: _storage).clearAll);
    await bestEffort(
      'settings',
      SettingsService(storage: _storage).clearSettings,
    );
  }
}
