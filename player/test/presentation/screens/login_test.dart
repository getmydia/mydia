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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/login_screen.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  group('LoginScreen.offersQrScan', () {
    test('offered on a phone, where the camera is the fast path', () {
      expect(LoginScreen.offersQrScan(directionalPrimary: false), isTrue);
    });

    test('withheld on a television, which has no camera to open', () {
      expect(LoginScreen.offersQrScan(directionalPrimary: true), isFalse);
    });
  });

  // Both layouts (card and TV) carry the segmented control and the
  // Connect button, so this holds in either tier.
  testWidgets('renders in Spanish when the locale is es', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        authServiceProvider
            .overrideWithValue(AuthService(storage: MockAuthStorage())),
      ],
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LoginScreen(),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Vinculación rápida'), findsOneWidget);
    expect(find.text('Servidor directo'), findsOneWidget);
    expect(find.text('Conectar'), findsOneWidget);
    expect(find.text('Quick Pair'), findsNothing);
  });
}
