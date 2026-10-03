import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/plex/plex_identity.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/source_factories.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/sources/plex_sign_in_controller.dart';

import '../../../core/sources/plex/plex_tv_client_test.dart' show resourcesJson;
import '../../../test_utils/mock_auth_storage.dart';

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue);
}

void main() {
  late String? pinToken;
  late String? pinBody;
  late MockAuthStorage storage;
  late InMemorySourceStore store;
  late ProviderContainer container;

  setUp(() {
    pinToken = null;
    pinBody = null;
    storage = MockAuthStorage();
    store = InMemorySourceStore();
    final client = MockClient((request) async {
      switch ('${request.method} ${request.url.path}') {
        case 'POST /api/v2/pins':
          return http.Response(
              pinBody ?? jsonEncode({'id': 7, 'code': 'QZ4K'}), 201);
        case 'GET /api/v2/pins/7':
          return http.Response(
              jsonEncode({'id': 7, 'authToken': pinToken}), 200);
        case 'GET /api/v2/user':
          return http.Response(
              jsonEncode({'uuid': 'u1', 'username': 'quill', 'title': 'Quill'}),
              200);
        case 'GET /api/v2/resources':
          return http.Response(resourcesJson, 200);
      }
      return http.Response('', 404);
    });
    container = ProviderContainer(overrides: [
      authStateProvider.overrideWith(_Unauthenticated.new),
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      sourceHttpProvider.overrideWithValue(SourceHttp(client: client)),
      plexIdentityProvider.overrideWith((ref) async => const PlexIdentity(
          clientIdentifier: 'cid', version: '1', platform: 'Linux')),
      plexPinPollIntervalProvider
          .overrideWithValue(const Duration(milliseconds: 10)),
    ]);
    addTearDown(container.dispose);
    container.listen(plexSignInProvider(null), (_, __) {});
  });

  PlexSignInState state() => container.read(plexSignInProvider(null));
  PlexSignInController controller() =>
      container.read(plexSignInProvider(null).notifier);

  test('an unexpected reply fails the sign-in instead of spinning', () async {
    pinBody = jsonEncode({'id': 'x'});
    await controller().start();
    expect(
        state(),
        isA<PlexSignInFailed>().having((s) => s.message, 'message',
            'Could not sign in to Plex. Try again.'));
  });

  test('shows the code, waits, then offers every server', () async {
    await controller().start();
    expect(state(),
        isA<PlexSignInWaiting>().having((s) => s.code, 'code', 'QZ4K'));

    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(state(), isA<PlexSignInWaiting>(), reason: 'not yet approved');

    pinToken = 'acct-token';
    await until(() => state() is PlexSignInChoosing);
    final choosing = state() as PlexSignInChoosing;
    expect(choosing.servers.map((s) => s.name), ['Attic', "Cousin's Box"]);
    expect(choosing.chosen, {'aa11', 'bb22'});
  });

  test('saves the chosen servers, their tokens, and selects the first',
      () async {
    pinToken = 'acct-token';
    await controller().start();
    await until(() => state() is PlexSignInChoosing);
    controller().toggle('bb22');
    await controller().save();

    expect(state(), isA<PlexSignInDone>());
    final snapshot = await store.load();
    final record = snapshot.accounts.single;
    expect(record.account.kind, SourceKind.plex);
    expect(record.account.displayName, 'quill');
    expect(record.servers.map((s) => s.id), ['aa11']);
    expect(
        await storage.read('${record.account.storageNamespace}/account_token'),
        'acct-token');
    expect(
      await storage.read('${record.account.storageNamespace}/owner/aa11/token'),
      'server-token-1',
    );
    final first = (state() as PlexSignInDone).firstSource;
    expect(container.read(activeSourceIdProvider), first);
  });

  test('re-auth replaces tokens on the same account and clears the flag',
      () async {
    pinToken = 'first';
    await controller().start();
    await until(() => state() is PlexSignInChoosing);
    await controller().save();
    final accountId = (await store.load()).accounts.single.account.id;
    await container
        .read(sourceRecordsProvider.notifier)
        .markNeedsReauth(accountId, true);

    container.listen(plexSignInProvider(accountId), (_, __) {});
    final again = container.read(plexSignInProvider(accountId).notifier);
    pinToken = 'second';
    await again.start();
    await until(() =>
        container.read(plexSignInProvider(accountId)) is PlexSignInChoosing);
    await again.save();

    final record = (await store.load()).accounts.single;
    expect(record.account.id, accountId);
    expect(record.account.needsReauth, isFalse);
    expect(await storage.read('source/$accountId/account_token'), 'second');
  });

  test('re-auth that drops a server deletes its stored token', () async {
    pinToken = 'first';
    await controller().start();
    await until(() => state() is PlexSignInChoosing);
    await controller().save();
    final accountId = (await store.load()).accounts.single.account.id;
    final record = (await store.load()).accounts.single;
    expect(record.servers.map((s) => s.id), ['aa11', 'bb22']);
    expect(await storage.read('source/$accountId/owner/bb22/token'),
        'server-token-2');

    container.listen(plexSignInProvider(accountId), (_, __) {});
    final again = container.read(plexSignInProvider(accountId).notifier);
    await again.start();
    await until(() =>
        container.read(plexSignInProvider(accountId)) is PlexSignInChoosing);
    again.toggle('bb22');
    await again.save();

    expect((await store.load()).accounts.single.servers.map((s) => s.id),
        ['aa11']);
    expect(await storage.read('source/$accountId/owner/aa11/token'),
        'server-token-1');
    expect(await storage.read('source/$accountId/owner/bb22/token'), isNull);
  });
}
