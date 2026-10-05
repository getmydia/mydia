// The add-server screen's Mydia tile reaches the login screen in guest mode,
// and a re-auth link carries the account it is for.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/router/app_router.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/login_screen.dart';
import 'package:player/presentation/screens/sources/add_source_screen.dart';

import '../../test_utils/mock_auth_storage.dart';

class _Authenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.authenticated);
}

/// Mounts the app router for a signed-in user at [location].
Future<GoRouter> _pump(WidgetTester tester, String location) async {
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
  router.go(location);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('a signed-in user reaches the guest login for an account',
      (tester) async {
    await _pump(tester, '/sources/add/mydia?account=mabc');

    final screen = tester.widget<LoginScreen>(find.byType(LoginScreen));
    expect(screen.guest, isNotNull);
    expect(screen.guest!.reauthAccountId, 'mabc');
    expect(find.text('Add a Mydia server'), findsOneWidget);
    // Nothing underneath to go back to.
    expect(find.byKey(const Key('login-back')), findsNothing);
  });

  // The login screen has no app bar, and iOS has no system back.
  testWidgets('pushed from Add a server, the guest login has a way back',
      (tester) async {
    final router = await _pump(tester, '/sources/add');
    unawaited(router.push('/sources/add/mydia'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('login-back')));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsNothing);
    expect(find.byType(AddSourceScreen), findsOneWidget);
  });
}
