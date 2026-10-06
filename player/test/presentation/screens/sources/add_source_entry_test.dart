// The only way in for someone with no Mydia server: the login screen's
// "connect Plex or Stash" button and the add-server screen behind it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/router/app_router.dart' show addMydiaRouteRedirect;
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/login_screen.dart';
import 'package:player/presentation/screens/sources/add_source_screen.dart';

import '../../../test_utils/mock_auth_storage.dart';

void main() {
  testWidgets('the login screen offers a way in that opens the add screen',
      (tester) async {
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/sources/add',
        builder: (_, __) => const SizedBox(key: Key('add-screen-marker')),
      ),
    ]);
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authServiceProvider
            .overrideWithValue(AuthService(storage: MockAuthStorage())),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    final button = find.byKey(const Key('connect-other-server'));
    expect(button, findsOneWidget);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('add-screen-marker')), findsOneWidget);
  });

  Future<void> pumpAdd(WidgetTester tester, {required bool mydia}) =>
      tester.pumpWidget(ProviderScope(
        overrides: [
          hasMydiaProvider.overrideWithValue(mydia),
        ],
        child: const MaterialApp(home: AddSourceScreen()),
      ));

  testWidgets('the add screen offers Plex, Stash and Mydia', (tester) async {
    await pumpAdd(tester, mydia: false);
    expect(find.byKey(const Key('add-source-plex')), findsOneWidget);
    expect(find.byKey(const Key('add-source-jellyfin')), findsOneWidget);
    expect(find.byKey(const Key('add-source-stash')), findsOneWidget);
    final mydia =
        tester.widget<ListTile>(find.byKey(const Key('add-source-mydia')));
    expect(mydia.enabled, isTrue);
  });

  testWidgets('with a Mydia account, the tile is enabled and adds another',
      (tester) async {
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const AddSourceScreen()),
      GoRoute(
        path: '/sources/add/mydia',
        builder: (_, __) => const SizedBox(key: Key('guest-marker')),
      ),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hasMydiaProvider.overrideWithValue(true),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    final tile = find.byKey(const Key('add-source-mydia'));
    expect(tester.widget<ListTile>(tile).enabled, isTrue);
    expect(
        find.text("Add a friend's or family member's server"), findsOneWidget);
    expect(find.textContaining('coming soon'), findsNothing);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('guest-marker')), findsOneWidget);
  });

  testWidgets('on web with a Mydia account, the tile is disabled with a hint',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hasMydiaProvider.overrideWithValue(true),
      ],
      child: const MaterialApp(home: AddSourceScreen(isWeb: true)),
    ));
    final tile =
        tester.widget<ListTile>(find.byKey(const Key('add-source-mydia')));
    expect(tile.enabled, isFalse);
    expect(find.text('Add more Mydia servers from the desktop or mobile app'),
        findsOneWidget);
  });

  testWidgets('on web without a Mydia account, the tile still signs in',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        hasMydiaProvider.overrideWithValue(false),
      ],
      child: const MaterialApp(home: AddSourceScreen(isWeb: true)),
    ));
    final tile =
        tester.widget<ListTile>(find.byKey(const Key('add-source-mydia')));
    expect(tile.enabled, isTrue);
    expect(find.text('Sign in to a Mydia server'), findsOneWidget);
  });

  test('the add Mydia route redirects home on an instance-hosted web only', () {
    expect(addMydiaRouteRedirect(hasMydia: true, instanceHostedWeb: true), '/');
    expect(addMydiaRouteRedirect(hasMydia: true, instanceHostedWeb: false),
        isNull);
  });

  testWidgets(
      'a re-auth retitles the login screen and hides the other-server link',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authServiceProvider
            .overrideWithValue(AuthService(storage: MockAuthStorage())),
      ],
      child: const MaterialApp(home: LoginScreen(reauthAccountId: 'mabc')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Add a Mydia server'), findsOneWidget);
    expect(find.byKey(const Key('connect-other-server')), findsNothing);
  });
}
