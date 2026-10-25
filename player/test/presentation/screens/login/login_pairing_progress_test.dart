// Pairing reports typed steps and typed failures; the screen words them. The
// controller no longer holds English, and no longer guesses the claim code
// status from the words.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/device_info_service.dart';
import 'package:player/core/channels/pairing_service.dart';
import 'package:player/l10n/gen/app_localizations_en.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/login/login_controller.dart';

import '../../../test_utils/no_downloads.dart';

class _FakeDeviceInfo extends DeviceInfoService {
  @override
  Future<String> getDeviceName() async => 'Test Device';
}

/// Reports [steps], then fails with [failure].
class _FailingPairing extends PairingService {
  _FailingPairing(this.steps, this.failure);
  final List<PairingStep> steps;
  final PairingFailure failure;

  @override
  Future<PairingResult> pairWithClaimCodeOnly({
    required String claimCode,
    required String deviceName,
    String? platform,
    void Function(PairingStep step)? onStatusUpdate,
  }) async {
    steps.forEach(onStatusUpdate ?? (_) {});
    return PairingResult.failure(failure.kind, detail: failure.detail);
  }

  @override
  Future<PairingResult> pairWithQrData({
    required QrPairingData qrData,
    required String deviceName,
    String? platform,
    void Function(PairingStep step)? onStatusUpdate,
  }) async {
    steps.forEach(onStatusUpdate ?? (_) {});
    return PairingResult.failure(failure.kind, detail: failure.detail);
  }
}

void main() {
  final en = AppLocalizationsEn();

  ProviderContainer containerFor(PairingService pairing) {
    final c = ProviderContainer(overrides: [
      ...noHiveOverrides,
      loginDeviceInfoProvider.overrideWithValue(_FakeDeviceInfo()),
      pairingServiceProvider.overrideWithValue(pairing),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('a claim code walks the steps and maps each to a status', () async {
    final c = containerFor(_FailingPairing(
      const [
        PairingStep.resolvingCode,
        PairingStep.initializing,
        PairingStep.connecting,
        PairingStep.submitting,
      ],
      const PairingFailure(PairingFailureKind.invalidCode),
    ));
    final seen = <(PairingStep?, ClaimCodeStatus)>[];
    c.listen(loginControllerProvider, (_, s) {
      seen.add((s.pairingStep, s.claimCodeStatus));
    });

    await c.read(loginControllerProvider.notifier).pairWithClaimCode('ABC123');

    expect(seen, [
      (PairingStep.lookingUpCode, ClaimCodeStatus.lookingUp),
      (PairingStep.resolvingCode, ClaimCodeStatus.resolving),
      (PairingStep.initializing, ClaimCodeStatus.handshaking),
      (PairingStep.connecting, ClaimCodeStatus.connecting),
      (PairingStep.submitting, ClaimCodeStatus.handshaking),
      (null, ClaimCodeStatus.error),
    ]);
  });

  test('a QR code starts at validating', () async {
    final c = containerFor(_FailingPairing(
      const [],
      const PairingFailure(PairingFailureKind.cannotConnect),
    ));
    final steps = <PairingStep?>[];
    c.listen(loginControllerProvider, (_, s) => steps.add(s.pairingStep));

    await c.read(loginControllerProvider.notifier).pairWithQrCode(
          const QrPairingData(nodeAddr: '{}', claimCode: 'ABC123'),
        );

    expect(steps.first, PairingStep.validatingQr);
  });

  test('a failed pairing carries its kind, worded by the screen', () async {
    final c = containerFor(_FailingPairing(
      const [],
      const PairingFailure(PairingFailureKind.invalidCode),
    ));
    c.listen(loginControllerProvider, (_, __) {});

    await c.read(loginControllerProvider.notifier).pairWithClaimCode('ABC123');

    final state = c.read(loginControllerProvider);
    final error = state.error;
    expect(error, isA<LoginFailureOfPairing>());
    expect(en.loginFailure(error!), 'Invalid or expired claim code');
    expect(state.claimCodeStatus, ClaimCodeStatus.error);
  });

  test('an unexpected failure keeps its technical detail verbatim', () {
    expect(
      en.loginFailure(const LoginFailureOfPairing(
          PairingFailure(PairingFailureKind.other, detail: 'Bad state: x'))),
      'Pairing failed: Bad state: x',
    );
    expect(
      en.loginFailure(const LoginFailureOfPairing(
          PairingFailure(PairingFailureKind.other))),
      'Pairing failed',
    );
  });

  test('every step and failure kind has text', () {
    for (final step in PairingStep.values) {
      expect(en.pairingStepText(step), isNotEmpty);
    }
    for (final kind in PairingFailureKind.values) {
      expect(
        en.loginFailure(LoginFailureOfPairing(PairingFailure(kind))),
        isNotEmpty,
      );
    }
  });
}
