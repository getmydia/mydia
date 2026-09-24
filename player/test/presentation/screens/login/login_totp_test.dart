// The code step of a direct-server login: once the server answers a correct
// password with a TOTP challenge, the credential fields give way to a single
// code field, whose submission and Back button reach the controller.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/presentation/screens/login/login_controller.dart';
import 'package:player/presentation/screens/login_screen.dart';

import '../../../test_utils/mock_auth_storage.dart';

class _FakeLoginController extends LoginController {
  String? submittedCode;
  bool cancelled = false;

  @override
  LoginState build() => const LoginState(
        mode: ConnectionMode.direct,
        totpChallenge: TotpChallenge(
          serverUrl: 'https://mydia.test',
          challengeToken: 'challenge',
          username: 'someone',
        ),
      );

  @override
  Future<void> submitTotpCode(String code) async => submittedCode = code;

  @override
  void cancelTotp() {
    cancelled = true;
    state = state.copyWith(clearTotpChallenge: true);
  }
}

Widget _buildTestWidget(_FakeLoginController controller) => ProviderScope(
      overrides: [
        authServiceProvider
            .overrideWithValue(AuthService(storage: MockAuthStorage())),
        loginControllerProvider.overrideWith(() => controller),
      ],
      child: const MaterialApp(home: LoginScreen()),
    );

/// Both the credential form and the code form live behind the Direct Server
/// tab; the tab selection is local widget state, not [LoginState.mode].
Future<void> _switchToDirectServerTab(WidgetTester tester) async {
  await tester.tap(find.text('Direct Server'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows only the code field while a challenge is pending',
      (tester) async {
    await tester.pumpWidget(_buildTestWidget(_FakeLoginController()));
    await tester.pumpAndSettle();
    await _switchToDirectServerTab(tester);

    expect(find.byKey(const Key('totp-code-field')), findsOneWidget);
    expect(find.text('Password'), findsNothing);
  });

  testWidgets('submits the typed code', (tester) async {
    final controller = _FakeLoginController();
    await tester.pumpWidget(_buildTestWidget(controller));
    await tester.pumpAndSettle();
    await _switchToDirectServerTab(tester);

    await tester.enterText(find.byKey(const Key('totp-code-field')), '123456');
    await tester.tap(find.byKey(const Key('totp-verify-button')));
    await tester.pump();

    expect(controller.submittedCode, '123456');
  });

  testWidgets('Back returns to the credential fields', (tester) async {
    final controller = _FakeLoginController();
    await tester.pumpWidget(_buildTestWidget(controller));
    await tester.pumpAndSettle();
    await _switchToDirectServerTab(tester);

    // The button sits below the fold at the default test surface size;
    // ensureVisible scrolls it into view so the tap actually hits it.
    final backButton = find.byKey(const Key('totp-back-button'));
    await tester.ensureVisible(backButton);
    await tester.tap(backButton);
    await tester.pumpAndSettle();

    expect(controller.cancelled, isTrue);
    expect(find.text('Password'), findsOneWidget);
  });
}
