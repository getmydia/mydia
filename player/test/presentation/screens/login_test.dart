// LoginScreen.offersQrScan decides whether to show the camera QR scanner
// button on the pairing screen. Withheld on a directional-primary device: a
// Chromecast with Google TV has no camera, so the button would only ever
// open a scanner that fails. Offered everywhere else, where the camera is
// the fast path to pairing.
//
// The predicate takes directionalPrimary as an explicit parameter rather
// than reading InputCapabilities.directionalPrimary itself, so both branches
// are exercised regardless of how the test process was compiled. That makes
// it tier-agnostic: it belongs in a plain test file, not a *_tv_test.dart
// one, since it needs no --dart-define=MYDIA_FORCE_TV=true to prove
// anything.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/login_screen.dart';

void main() {
  group('LoginScreen.offersQrScan', () {
    test('offered on a phone, where the camera is the fast path', () {
      expect(LoginScreen.offersQrScan(directionalPrimary: false), isTrue);
    });

    test('withheld on a television, which has no camera to open', () {
      expect(LoginScreen.offersQrScan(directionalPrimary: true), isFalse);
    });
  });
}
