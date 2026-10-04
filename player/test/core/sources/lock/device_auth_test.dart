import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:player/core/sources/lock/device_auth.dart';

class _FakeLocalAuth extends Fake implements LocalAuthentication {
  _FakeLocalAuth({this.supported = true, this.result, this.error});
  bool supported;
  final bool? result;
  final Object? error;
  String? reason;
  bool? biometricOnly;

  @override
  Future<bool> isDeviceSupported() async => supported;

  // `AuthMessages` lives in a transitive package, so the parameter is widened
  // to `dynamic`, which is still a valid override.
  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<dynamic> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    reason = localizedReason;
    this.biometricOnly = biometricOnly;
    // ignore: only_throw_errors
    if (error != null) throw error!;
    return result!;
  }
}

void main() {
  test('NoDeviceAuth is never available', () async {
    expect(await const NoDeviceAuth().available(), isFalse);
    expect(
      await const NoDeviceAuth().authenticate(),
      DeviceAuthResult.unavailable,
    );
  });

  test('allows the device passcode, not biometrics only', () async {
    final fake = _FakeLocalAuth(result: true);
    expect(
      await LocalAuthDeviceAuth(fake).authenticate(),
      DeviceAuthResult.success,
    );
    expect(fake.biometricOnly, isFalse);
    expect(fake.reason, 'Unlock hidden and locked servers');
  });

  test('false from the plugin is a cancel', () async {
    expect(
      await LocalAuthDeviceAuth(_FakeLocalAuth(result: false)).authenticate(),
      DeviceAuthResult.cancelled,
    );
  });

  test('a user cancel exception (local_auth 3.x) is a cancel', () async {
    for (final code in [
      LocalAuthExceptionCode.userCanceled,
      LocalAuthExceptionCode.systemCanceled,
      LocalAuthExceptionCode.userRequestedFallback,
    ]) {
      final fake = _FakeLocalAuth(error: LocalAuthException(code: code));
      expect(
        await LocalAuthDeviceAuth(fake).authenticate(),
        DeviceAuthResult.cancelled,
        reason: '$code',
      );
    }
  });

  test('unsupported device is unavailable without prompting', () async {
    final fake = _FakeLocalAuth(supported: false, result: true);
    expect(await LocalAuthDeviceAuth(fake).available(), isFalse);
    expect(
      await LocalAuthDeviceAuth(fake).authenticate(),
      DeviceAuthResult.unavailable,
    );
    expect(fake.reason, isNull);
  });

  test('an exception is a failure', () async {
    final fake = _FakeLocalAuth(error: Exception('boom'));
    expect(
      await LocalAuthDeviceAuth(fake).authenticate(),
      DeviceAuthResult.failed,
    );
  });
}
