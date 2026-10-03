// The only way in for someone with no Mydia server: the login screen's
// "connect Plex or Stash" button and the add-server screen behind it.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/auth/auth_service.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/screens/login_screen.dart';
import 'package:player/presentation/screens/sources/add_source_screen.dart';

import '../../../test_utils/mock_auth_storage.dart';

class _MydiaPresent extends MydiaPresenceNotifier {
  _MydiaPresent(this.present);
  final bool present;

  @override
  bool build() => present;
}

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
          mydiaPresentProvider.overrideWith(() => _MydiaPresent(mydia)),
        ],
        child: const MaterialApp(home: AddSourceScreen()),
      ));

  testWidgets('the add screen offers Plex, Stash and Mydia', (tester) async {
    await pumpAdd(tester, mydia: false);
    expect(find.byKey(const Key('add-source-plex')), findsOneWidget);
    expect(find.byKey(const Key('add-source-stash')), findsOneWidget);
    final mydia =
        tester.widget<ListTile>(find.byKey(const Key('add-source-mydia')));
    expect(mydia.enabled, isTrue);
  });

  testWidgets('a second Mydia server is disabled as coming soon',
      (tester) async {
    await pumpAdd(tester, mydia: true);
    final mydia =
        tester.widget<ListTile>(find.byKey(const Key('add-source-mydia')));
    expect(mydia.enabled, isFalse);
    expect(find.text('Multiple Mydia servers: coming soon'), findsOneWidget);
  });
}
