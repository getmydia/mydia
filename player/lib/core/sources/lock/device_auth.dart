/// Face ID, Touch ID, fingerprint, Windows Hello or the device passcode,
/// whichever the OS offers. Where it offers none, the PIN takes over.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

enum DeviceAuthResult { success, cancelled, unavailable, failed }

abstract class DeviceAuth {
  Future<bool> available();
  Future<DeviceAuthResult> authenticate();
}

/// Linux and web: `local_auth` has no implementation there, and calling it
/// throws `MissingPluginException`.
class NoDeviceAuth implements DeviceAuth {
  const NoDeviceAuth();

  @override
  Future<bool> available() async => false;

  @override
  Future<DeviceAuthResult> authenticate() async => DeviceAuthResult.unavailable;
}

class LocalAuthDeviceAuth implements DeviceAuth {
  LocalAuthDeviceAuth(this._auth);

  final LocalAuthentication _auth;

  /// local_auth 3.x reports a dismissed prompt by throwing rather than by
  /// returning false.
  static const _cancelCodes = {
    LocalAuthExceptionCode.userCanceled,
    LocalAuthExceptionCode.systemCanceled,
    LocalAuthExceptionCode.userRequestedFallback,
  };

  /// False on a phone or TV with no screen lock: the OS has nothing to
  /// check against.
  @override
  Future<bool> available() async {
    try {
      return await _auth.isDeviceSupported();
    } catch (e) {
      debugPrint('[SourceLock] device auth support check failed: $e');
      return false;
    }
  }

  @override
  Future<DeviceAuthResult> authenticate() async {
    if (!await available()) return DeviceAuthResult.unavailable;
    try {
      final ok = await _auth.authenticate(
        localizedReason: 'Unlock hidden and locked servers',
        // The OS falls back to the device passcode when biometrics fail or
        // are not enrolled.
        biometricOnly: false,
      );
      return ok ? DeviceAuthResult.success : DeviceAuthResult.cancelled;
    } on LocalAuthException catch (e) {
      if (_cancelCodes.contains(e.code)) return DeviceAuthResult.cancelled;
      debugPrint('[SourceLock] device auth failed: ${e.code}');
      return await available()
          ? DeviceAuthResult.failed
          : DeviceAuthResult.unavailable;
    } catch (e) {
      debugPrint('[SourceLock] device auth failed: $e');
      return await available()
          ? DeviceAuthResult.failed
          : DeviceAuthResult.unavailable;
    }
  }
}

final deviceAuthProvider = Provider<DeviceAuth>((ref) {
  if (kIsWeb || Platform.isLinux) return const NoDeviceAuth();
  return LocalAuthDeviceAuth(LocalAuthentication());
});
