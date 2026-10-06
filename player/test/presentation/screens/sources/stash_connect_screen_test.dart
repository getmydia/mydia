import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/source_factories.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/sources/stash_connect_screen.dart';

import '../../../core/sources/stash/fake_stash_server.dart';
import '../../../test_utils/mock_auth_storage.dart';

class _FailingStore extends InMemorySourceStore {
  @override
  Future<void> putAccount(SourceAccountRecord record) =>
      throw StateError('disk full');
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

  test('keeps a reverse-proxy subpath', () {
    expect(parseStashUrl('https://host.example.test/stash/').toString(),
        'https://host.example.test/stash');
    expect(parseStashUrl('host.example.test:9999/a/b').toString(),
        'http://host.example.test:9999/a/b');
  });

  group('the API key and plain HTTP', () {
    const refusal = 'Use https:// for a Stash server outside your network';

    // A server that answers 401 and counts requests, so "was not refused"
    // is "the request went out".
    Future<int> submit(WidgetTester tester, String url, String key) async {
      var requests = 0;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sourceStoreProvider
              .overrideWith((ref) async => InMemorySourceStore()),
          sourceSecretsProvider
              .overrideWithValue(SourceSecrets(MockAuthStorage())),
          sourceHttpProvider
              .overrideWithValue(SourceHttp(client: MockClient((_) async {
            requests++;
            return http.Response('', 401);
          }))),
        ],
        child: const MaterialApp(home: StashConnectScreen()),
      ));
      await tester.enterText(find.byKey(const Key('stash-url-field')), url);
      await tester.enterText(find.byKey(const Key('stash-key-field')), key);
      await tester.tap(find.byKey(const Key('stash-connect-button')));
      await tester.pumpAndSettle();
      return requests;
    }

    testWidgets('refuses a key over http to a host outside the network',
        (tester) async {
      final requests = await submit(tester, 'http://stash.example.test', 'k');
      expect(requests, 0);
      expect(find.textContaining(refusal), findsOneWidget);
    });

    for (final url in [
      'http://192.168.1.20:9999',
      'http://100.101.102.103:9999',
      'http://nas.tail1234.ts.net:9999',
      'https://stash.example.test',
    ]) {
      testWidgets('lets a key go to $url', (tester) async {
        final requests = await submit(tester, url, 'k');
        expect(requests, greaterThan(0));
        expect(find.textContaining(refusal), findsNothing);
      });
    }

    testWidgets('does not refuse http without a key', (tester) async {
      final requests = await submit(tester, 'http://stash.example.test', '');
      expect(requests, greaterThan(0));
      expect(find.textContaining(refusal), findsNothing);
    });
  });

  testWidgets('says so when the server cannot be saved on this device',
      (tester) async {
    final server = FakeStashServer();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sourceStoreProvider.overrideWith((ref) async => _FailingStore()),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
        sourceHttpProvider.overrideWithValue(SourceHttp(client: server.client)),
      ],
      child: const MaterialApp(home: StashConnectScreen()),
    ));
    await tester.enterText(
        find.byKey(const Key('stash-url-field')), '192.168.1.20:9999');
    await tester.enterText(
        find.byKey(const Key('stash-key-field')), FakeStashServer.apiKey);
    await tester.tap(find.byKey(const Key('stash-connect-button')));
    await tester.pumpAndSettle();
    expect(find.text('Could not save this server on this device.'),
        findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('a rejected key says where to find the right one',
      (tester) async {
    final server = FakeStashServer();
    await tester.pumpWidget(ProviderScope(
      overrides: [
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

  testWidgets('re-saving an account with an empty key removes the old key',
      (tester) async {
    final server = FakeStashServer();
    final storage = MockAuthStorage();
    final store = InMemorySourceStore();

    // First, save with an API key
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
        sourceHttpProvider.overrideWithValue(SourceHttp(client: server.client)),
      ],
      child: const MaterialApp(home: StashConnectScreen()),
    ));

    await tester.enterText(
        find.byKey(const Key('stash-url-field')), '192.168.1.20:9999');
    await tester.enterText(
        find.byKey(const Key('stash-key-field')), FakeStashServer.apiKey);
    await tester.tap(find.byKey(const Key('stash-connect-button')));
    await tester.pumpAndSettle();

    final record = (await store.load()).accounts.single;
    final accountToken =
        await storage.read('${record.account.storageNamespace}/account_token');
    expect(accountToken, FakeStashServer.apiKey);

    // Now re-auth with an empty key using a mock client that accepts no key
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
        sourceHttpProvider.overrideWithValue(SourceHttp(
          client: MockClient((_) async => http.Response(
              '{"data":{"systemStatus":{"status":"OK"}}}', 200,
              headers: {'content-type': 'application/json'})),
        )),
      ],
      child: MaterialApp(
        home: StashConnectScreen(reauthAccountId: record.account.id),
      ),
    ));
    await tester.pumpAndSettle();

    // The URL field should be pre-populated
    expect(find.byWidgetPredicate((w) {
      return w is TextField &&
          w.controller?.text.contains('192.168.1.20') == true;
    }), findsOneWidget);

    // Clear the key field (which should be empty) and submit
    await tester.enterText(find.byKey(const Key('stash-key-field')), '');
    await tester.tap(find.byKey(const Key('stash-connect-button')));
    await tester.pumpAndSettle();

    // Verify the old key is deleted
    final updatedToken =
        await storage.read('${record.account.storageNamespace}/account_token');
    expect(updatedToken, isNull);
  });
}
