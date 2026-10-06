import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/sources/plex/plex_identity.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/source_factories.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/sources/plex_home_sheet.dart';

import '../../../core/sources/plex/plex_home_fixtures.dart';
import '../../../core/sources/store/source_json_test.dart' show plexRecord;
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/toast_harness.dart';

/// plexRecord's server is `abc123`; Pip sees it under that id.
const _kidResources = '''
[{"name": "Attic", "provides": "server", "clientIdentifier": "abc123",
  "owned": false, "presence": true, "accessToken": "kid-srv",
  "httpsRequired": false, "connections": []}]
''';

void main() {
  late InMemorySourceStore store;
  late MockAuthStorage storage;
  late List<SourceId> switched;
  bool homeUsersFail = false;
  bool homeUsersGone = false;
  Completer<void>? guestGate;

  Future<ProviderContainer> pump(WidgetTester tester) async {
    store = InMemorySourceStore();
    await store.putAccount(plexRecord());
    storage = MockAuthStorage();
    await storage.write('source/acc1/account_token', 'acct');
    switched = [];
    final client = MockClient((request) async {
      switch ('${request.method} ${request.url.path}') {
        case 'GET /api/v2/home/users':
          if (homeUsersGone) return http.Response('', 404);
          return homeUsersFail
              ? http.Response('', 500)
              : http.Response(homeUsersJson, 200);
        case 'POST /api/v2/home/users/kid0001/switch':
          return request.url.queryParameters['pin'] == '1234'
              ? http.Response(kidSwitchJson, 201)
              : http.Response(wrongPinJson, 401);
        case 'POST /api/v2/home/users/guest02/switch':
          await guestGate?.future;
          return http.Response(guestSwitchJson, 201);
        case 'GET /api/v2/resources':
          return http.Response(_kidResources, 200);
      }
      return http.Response('', 404);
    });
    final container = ProviderContainer(overrides: [
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      sourceHttpProvider.overrideWithValue(SourceHttp(client: client)),
      plexIdentityProvider.overrideWith((ref) async => const PlexIdentity(
          clientIdentifier: 'cid', version: '1', platform: 'Linux')),
    ]);
    addTearDown(container.dispose);
    await container.read(sourceRecordsProvider.future);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        builder: toastLayerBuilder,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPlexHomeSheet(context,
                  account: plexRecord().account,
                  serverId: 'abc123',
                  onSwitched: switched.add),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return container;
  }

  setUp(() {
    homeUsersFail = false;
    homeUsersGone = false;
    guestGate = null;
  });

  testWidgets('lists the Home users with a lock on protected ones',
      (tester) async {
    await pump(tester);
    expect(find.byKey(const Key('plex-home-user-owner')), findsOneWidget);
    expect(find.byKey(const Key('plex-home-user-kid0001')), findsOneWidget);
    expect(find.byKey(const Key('plex-home-user-guest02')), findsOneWidget);
    expect(
      find.descendant(
          of: find.byKey(const Key('plex-home-user-kid0001')),
          matching: find.byIcon(Icons.lock_rounded)),
      findsOneWidget,
    );
  });

  testWidgets('a protected user switches after the right PIN', (tester) async {
    final container = await pump(tester);
    await tester.tap(find.byKey(const Key('plex-home-user-kid0001')));
    await tester.pumpAndSettle();
    for (final d in '0000'.split('')) {
      await tester.tap(find.byKey(Key('plex-pin-key-$d')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plex-pin-error')), findsOneWidget);

    for (final d in '1234'.split('')) {
      await tester.tap(find.byKey(Key('plex-pin-key-$d')));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(switched, [const SourceId('acc1:kid0001:abc123')]);
    expect(container.read(activeSourceIdProvider),
        const SourceId('acc1:kid0001:abc123'));
    expect(find.byKey(const Key('plex-home-user-kid0001')), findsNothing,
        reason: 'the sheet closes after a switch');
  });

  testWidgets('a switch still completes when the sheet is dismissed mid-way',
      (tester) async {
    guestGate = Completer<void>();
    final container = await pump(tester);
    await tester.tap(find.byKey(const Key('plex-home-user-guest02')));
    await tester.pump();
    Navigator.of(
            tester.element(find.byKey(const Key('plex-home-user-guest02'))))
        .pop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plex-home-user-guest02')), findsNothing);

    guestGate!.complete();
    await tester.pumpAndSettle();

    expect(switched, [const SourceId('acc1:guest02:abc123')]);
    expect(container.read(activeSourceIdProvider),
        const SourceId('acc1:guest02:abc123'));
  });

  testWidgets('a failed user list shows an error', (tester) async {
    homeUsersFail = true;
    await pump(tester);
    expect(find.byKey(const Key('plex-home-error')), findsOneWidget);
  });

  testWidgets('a dissolved Home says there are no other users', (tester) async {
    homeUsersGone = true;
    await pump(tester);
    expect(find.byKey(const Key('plex-home-empty')), findsOneWidget);
  });
}
