import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/connection/connection_refresh_bus.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/plex/plex_identity.dart';
import 'package:player/core/sources/plex/plex_media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/source_factories.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/stash/stash_media_source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/source_error.dart';

import '../../test_utils/mock_auth_storage.dart';
import 'plex/fake_plex_server.dart';
import 'stash/fake_stash_server.dart';
import 'stash/stash_media_source_test.dart' show stashRecord;

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

final atticRecord = SourceAccountRecord(
  account: const ProviderAccount(
    id: 'acc1',
    kind: SourceKind.plex,
    displayName: 'quill',
    storageNamespace: 'source/acc1',
    activeProfileId: 'owner',
  ),
  profiles: const [
    SourceProfile(id: 'owner', accountId: 'acc1', name: 'Quill', isOwner: true),
  ],
  servers: [
    SourceServer(
      id: FakePlexServer.machineId,
      accountId: 'acc1',
      profileId: 'owner',
      name: 'Attic',
      machineIdentifier: FakePlexServer.machineId,
      connections: [ServerConnection(uri: FakePlexServer.base, local: true)],
    ),
  ],
  addedAtMs: 0,
);

const atticId = SourceId('acc1:owner:aa11');

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<ProviderContainer> containerFor({
  required SourceAccountRecord record,
  required SourceHttp http,
  required Map<String, String> secrets,
}) async {
  final store = InMemorySourceStore();
  await store.putAccount(record);
  final storage = MockAuthStorage();
  for (final e in secrets.entries) {
    await storage.write(e.key, e.value);
  }
  final container = ProviderContainer(overrides: [
    authStateProvider.overrideWith(_Unauthenticated.new),
    sourceStoreProvider.overrideWith((ref) async => store),
    sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
    sourceHttpProvider.overrideWithValue(http),
    plexIdentityProvider.overrideWith((ref) async => const PlexIdentity(
        clientIdentifier: 'cid', version: '1', platform: 'Linux')),
  ]);
  addTearDown(container.dispose);
  await container.read(sourceRecordsProvider.future);
  return container;
}

void main() {
  late FakePlexServer plex;
  late ProviderContainer container;

  setUp(() async {
    plex = FakePlexServer();
    container = await containerFor(
      record: atticRecord,
      http: SourceHttp(client: plex.client),
      secrets: {'source/acc1/owner/aa11/token': FakePlexServer.token},
    );
  });

  test('builds a live Plex source that browses', () async {
    final media = container.read(mediaSourceProvider(atticId));
    expect(media, isA<PlexMediaSource>());
    expect(await media!.libraries(), hasLength(2));
    expect(media.connection, SourceConnectionStatus.local);
  });

  test('a 401 flags the account without rebuilding the source', () async {
    final media = container.read(mediaSourceProvider(atticId))!;
    await media.libraries();
    plex.status = 401;
    await expectLater(media.libraries(), throwsA(isA<SourceException>()));
    await settle();
    expect(container.read(thirdPartySourcesProvider).single.account.needsReauth,
        isTrue);
    expect(
        identical(container.read(mediaSourceProvider(atticId)), media), isTrue);
  });

  test('a resume ping makes the source look again', () async {
    final media = container.read(mediaSourceProvider(atticId))!;
    await media.libraries();
    int probes() =>
        plex.requests.where((r) => r.url.path == '/identity').length;
    final before = probes();
    container
        .read(connectionRefreshBusProvider)
        .ping(ConnectionRefreshReason.resume);
    await settle();
    expect(probes(), greaterThan(before));
  });

  test('removing the account removes the source', () async {
    container.listen(mediaSourceProvider(atticId), (_, __) {});
    await container.read(sourceRecordsProvider.notifier).removeAccount('acc1');
    expect(container.read(mediaSourceProvider(atticId)), isNull);
  });

  test('builds a Stash source from the stored API key', () async {
    final stash = FakeStashServer();
    final c = await containerFor(
      record: stashRecord,
      http: SourceHttp(client: stash.client),
      secrets: {'source/st1/account_token': FakeStashServer.apiKey},
    );
    final media = c.read(mediaSourceProvider(const SourceId('st1:owner:main')));
    expect(media, isA<StashMediaSource>());
    expect(
      (await media!.browse(
              (await media.libraries()).single.ref, const BrowseQuery()))
          .items,
      hasLength(5),
    );
  });
}
