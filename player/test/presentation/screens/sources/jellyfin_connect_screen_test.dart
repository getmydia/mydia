import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/jellyfin/jellyfin_identity.dart';
import 'package:player/core/sources/source_factories.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/sources/jellyfin_connect_screen.dart';
import 'package:player/presentation/screens/sources/jellyfin_sign_in_controller.dart';

import '../../../core/sources/jellyfin/fake_jellyfin_server.dart';
import '../../../core/sources/jellyfin/jellyfin_media_source_test.dart'
    show jellyfinRecord;
import '../../../test_utils/mock_auth_storage.dart';

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

Future<FakeJellyfinServer> pumpScreen(WidgetTester tester,
    {bool quickConnect = true, String? reauthAccountId}) async {
  final server = FakeJellyfinServer()..quickConnectEnabled = quickConnect;
  final store = InMemorySourceStore();
  if (reauthAccountId != null) await store.putAccount(jellyfinRecord);
  final router = GoRouter(
    initialLocation: '/sources/add/jellyfin',
    routes: [
      GoRoute(
          path: '/sources/add/jellyfin',
          builder: (_, __) =>
              JellyfinConnectScreen(reauthAccountId: reauthAccountId)),
      GoRoute(
          path: '/s/:id',
          builder: (_, s) => Text('opened ${s.pathParameters['id']}')),
    ],
  );
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(_Unauthenticated.new),
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
      sourceHttpProvider.overrideWithValue(SourceHttp(client: server.client)),
      jellyfinIdentityProvider.overrideWith((ref) async =>
          const JellyfinIdentity(
              deviceId: 'dev1',
              version: '1',
              deviceName: 'Mydia Player on Linux')),
      jellyfinQuickConnectPollProvider
          .overrideWithValue(const Duration(milliseconds: 50)),
    ],
  );
  addTearDown(container.dispose);
  // The screen reads the stored sources once, in initState.
  await container.read(sourceRecordsProvider.future);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  ));
  return server;
}

Future<void> enterAddress(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('jellyfin-url-field')),
      'https://media.example.test');
  await tester.tap(find.byKey(const Key('jellyfin-continue-button')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the Quick Connect code, then opens the server',
      (tester) async {
    final server = await pumpScreen(tester);
    await enterAddress(tester);
    expect(find.text('482913'), findsOneWidget);
    server.quickConnectApproved = true;
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();
    expect(find.textContaining('opened '), findsOneWidget);
  });

  testWidgets('an expired code offers a new one', (tester) async {
    final server = await pumpScreen(tester);
    await enterAddress(tester);
    expect(
        find.byKey(const Key('jellyfin-quick-connect-code')), findsOneWidget);
    server.quickConnectExpired = true;
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpAndSettle();
    expect(find.text('Code expired.'), findsOneWidget);
    expect(find.byKey(const Key('jellyfin-new-code-button')), findsOneWidget);
    expect(find.byKey(const Key('jellyfin-quick-connect-code')), findsNothing);

    server.quickConnectExpired = false;
    await tester.tap(find.byKey(const Key('jellyfin-new-code-button')));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const Key('jellyfin-quick-connect-code')), findsOneWidget);
    // Dispose the providers so the poll timer is cancelled before the test
    // ends; the tear-down would run after the pending-timer check.
    ProviderScope.containerOf(
            tester.element(find.byType(JellyfinConnectScreen)))
        .dispose();
  });

  testWidgets('re-authenticating prefills the address and username',
      (tester) async {
    await pumpScreen(tester, reauthAccountId: 'jf1');
    final field =
        tester.widget<TextField>(find.byKey(const Key('jellyfin-url-field')));
    expect(field.controller?.text, contains('https://media.example.test'));
  });

  testWidgets('password sign-in when Quick Connect is off', (tester) async {
    await pumpScreen(tester, quickConnect: false);
    await enterAddress(tester);
    expect(find.byKey(const Key('jellyfin-use-quick-connect-button')),
        findsNothing);
    await tester.enterText(find.byKey(const Key('jellyfin-username-field')),
        FakeJellyfinServer.username);
    await tester.enterText(find.byKey(const Key('jellyfin-password-field')),
        FakeJellyfinServer.password);
    await tester.tap(find.byKey(const Key('jellyfin-sign-in-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('opened '), findsOneWidget);
  });

  testWidgets('a wrong password shows the error', (tester) async {
    await pumpScreen(tester, quickConnect: false);
    await enterAddress(tester);
    await tester.enterText(
        find.byKey(const Key('jellyfin-username-field')), 'marlow');
    await tester.enterText(
        find.byKey(const Key('jellyfin-password-field')), 'nope');
    await tester.tap(find.byKey(const Key('jellyfin-sign-in-button')));
    await tester.pumpAndSettle();
    expect(find.text('Wrong username or password.'), findsOneWidget);
  });

  testWidgets('on the code screen a remote lands on "use password"',
      (tester) async {
    await pumpScreen(tester);
    await enterAddress(tester);
    // The code is read, not typed, so the only control is focused and a
    // remote's select key activates it.
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(
      focused == null
          ? null
          : find
              .ancestor(
                  of: find.byWidget(focused.widget),
                  matching:
                      find.byKey(const Key('jellyfin-use-password-button')))
              .evaluate()
              .isNotEmpty,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('jellyfin-username-field')), findsOneWidget);
  });
}
