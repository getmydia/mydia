// The add-server screen's Mydia tile reaches the login screen,
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

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

/// Mounts the app router at [location], for a signed-in user unless
/// [signedIn] is false.
Future<GoRouter> _pump(
  WidgetTester tester,
  String location, {
  bool signedIn = true,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(overrides: [
    authStateProvider
        .overrideWith(signedIn ? _Authenticated.new : _Unauthenticated.new),
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
  testWidgets('a signed-in user reaches the login for an account',
      (tester) async {
    await _pump(tester, '/sources/add/mydia?account=mabc');

    final screen = tester.widget<LoginScreen>(find.byType(LoginScreen));
    expect(screen.reauthAccountId, 'mabc');
    expect(find.text('Add a Mydia server'), findsOneWidget);
    // Nothing underneath to go back to.
    expect(find.byKey(const Key('login-back')), findsNothing);
  });

  // The login screen has no app bar, and iOS has no system back.
  testWidgets('pushed from Add a server, the login has a way back',
      (tester) async {
    final router = await _pump(tester, '/sources/add');
    unawaited(router.push('/sources/add/mydia'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('login-back')));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsNothing);
    expect(find.byType(AddSourceScreen), findsOneWidget);
  });

  testWidgets(
      'with no Mydia server, the Mydia tile opens login with a way back',
      (tester) async {
    final router = await _pump(tester, '/sources/add', signedIn: false);
    await tester.tap(find.byKey(const Key('add-source-mydia')));
    await tester.pumpAndSettle();

    // A pushed route is the last match; `uri` still names the page below it.
    expect(router.routerDelegate.currentConfiguration.last.matchedLocation,
        '/sources/add/mydia');
    final screen = tester.widget<LoginScreen>(find.byType(LoginScreen));
    expect(screen.reauthAccountId, isNull);

    await tester.tap(find.byKey(const Key('login-back')));
    await tester.pumpAndSettle();
    expect(find.byType(LoginScreen), findsNothing);
    expect(find.byType(AddSourceScreen), findsOneWidget);
  });

  testWidgets('/login redirects to /sources/add/mydia and keeps its query',
      (tester) async {
    final router = await _pump(tester, '/login?x=1', signedIn: false);

    expect(router.state.uri.toString(), '/sources/add/mydia?x=1');
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  group('addMydiaRouteRedirect on an instance-hosted web build', () {
    test('with no Mydia account it stays, so sign-in cannot loop', () {
      expect(addMydiaRouteRedirect(hasMydia: false, instanceHostedWeb: true),
          isNull);
      // `/login` -> `/sources/add/mydia` stays put for a signed-out viewer.
      expect(
        appRedirect(
          auth: const AsyncData(AuthStatus.unauthenticated),
          location: '/sources/add/mydia',
          sourcesLoading: false,
          thirdParty: const [],
        ),
        isNull,
      );
    });

    test('with a Mydia account it redirects to /', () {
      expect(
          addMydiaRouteRedirect(hasMydia: true, instanceHostedWeb: true), '/');
    });

    test('off the instance-hosted web it never redirects', () {
      expect(addMydiaRouteRedirect(hasMydia: true, instanceHostedWeb: false),
          isNull);
    });
  });
}
