import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/presentation/screens/login/login_controller.dart';

void main() {
  group('LoginState.credentialsNotPersisted', () {
    test('defaults to false', () {
      expect(const LoginState().credentialsNotPersisted, isFalse);
    });

    test('is set through copyWith', () {
      final state = const LoginState().copyWith(credentialsNotPersisted: true);

      expect(state.credentialsNotPersisted, isTrue);
    });

    test('survives an unrelated copyWith', () {
      // The warning must not be dropped by the next state update, which is
      // what would happen if it were treated like the transient error field.
      final state = const LoginState()
          .copyWith(credentialsNotPersisted: true)
          .copyWith(isLoading: false);

      expect(state.credentialsNotPersisted, isTrue);
    });
  });

  group('LoginState.totpChallenge', () {
    const challenge = TotpChallenge(
      serverUrl: 'https://mydia.test',
      challengeToken: 'challenge',
      username: 'someone',
    );

    test('defaults to null', () {
      expect(const LoginState().totpChallenge, isNull);
    });

    test('survives an unrelated copyWith', () {
      final state = const LoginState()
          .copyWith(totpChallenge: challenge)
          .copyWith(isLoading: true);

      expect(state.totpChallenge, same(challenge));
    });

    test('is cleared by clearTotpChallenge', () {
      final state = const LoginState()
          .copyWith(totpChallenge: challenge)
          .copyWith(clearTotpChallenge: true);

      expect(state.totpChallenge, isNull);
    });
  });
}
