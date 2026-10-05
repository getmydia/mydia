// The add-server screen's Mydia tile reaches the login screen in guest mode,
// and a re-auth link carries the account it is for.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/router/app_router.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/login_screen.dart';

import '../../test_utils/mock_auth_storage.dart';

class _Authenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.authenticated);
}

void main() {
  testWidgets('a signed-in user reaches the guest login for an account',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer(overrides: [
      authStateProvider.overrideWith(_Authenticated.new),
      sourceStoreProvider.overrideWith((ref) async => InMemorySourceStore()),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
      authServiceProvider
          .overrideWithValue(AuthService(storage: MockAuthStorage())),
    ]);
    addTearDown(container.dispose);

    final router = container.read(appRouterProvider);
    router.go('/sources/add/mydia?account=mabc');
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    final screen = tester.widget<LoginScreen>(find.byType(LoginScreen));
    expect(screen.guest, isNotNull);
    expect(screen.guest!.reauthAccountId, 'mabc');
    expect(find.text('Add a Mydia server'), findsOneWidget);
  });
}
