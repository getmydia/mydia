import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/source_factories.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/sources/stash_connect_screen.dart';

import '../../../core/sources/stash/fake_stash_server.dart';
import '../../../test_utils/mock_auth_storage.dart';

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

void main() {
  test('parses what people type', () {
    expect(parseStashUrl('192.168.1.20:9999').toString(),
        'http://192.168.1.20:9999');
    expect(parseStashUrl(' https://stash.example.test/ ').toString(),
        'https://stash.example.test');
    expect(parseStashUrl(''), isNull);
    expect(parseStashUrl('ftp://x'), isNull);
  });

  testWidgets('checks the server, saves it and opens it', (tester) async {
    final server = FakeStashServer();
    final storage = MockAuthStorage();
    final store = InMemorySourceStore();
    final router = GoRouter(
      initialLocation: '/sources/add/stash',
      routes: [
        GoRoute(
            path: '/sources/add/stash',
            builder: (_, __) => const StashConnectScreen()),
        GoRoute(
            path: '/s/:id',
            builder: (_, s) => Text('opened ${s.pathParameters['id']}')),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authStateProvider.overrideWith(_Unauthenticated.new),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
        sourceHttpProvider.overrideWithValue(SourceHttp(client: server.client)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));

    await tester.enterText(
        find.byKey(const Key('stash-url-field')), '192.168.1.20:9999');
    await tester.enterText(
        find.byKey(const Key('stash-key-field')), FakeStashServer.apiKey);
    await tester.tap(find.byKey(const Key('stash-connect-button')));
    await tester.pumpAndSettle();

    final record = (await store.load()).accounts.single;
    expect(record.servers.single.connections.single.uri,
        Uri.parse('http://192.168.1.20:9999'));
    expect(record.servers.single.connections.single.local, isTrue);
    expect(
        await storage.read('${record.account.storageNamespace}/account_token'),
        FakeStashServer.apiKey);
    expect(find.textContaining('opened ${record.account.id}:owner:main'),
        findsOneWidget);
  });

  testWidgets('a rejected key says where to find the right one',
      (tester) async {
    final server = FakeStashServer();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        authStateProvider.overrideWith(_Unauthenticated.new),
        sourceStoreProvider.overrideWith((ref) async => InMemorySourceStore()),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
        sourceHttpProvider.overrideWithValue(SourceHttp(client: server.client)),
      ],
      child: const MaterialApp(home: StashConnectScreen()),
    ));
    await tester.enterText(
        find.byKey(const Key('stash-url-field')), '192.168.1.20:9999');
    await tester.enterText(find.byKey(const Key('stash-key-field')), 'wrong');
    await tester.tap(find.byKey(const Key('stash-connect-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Settings, Security'), findsOneWidget);
  });
}
