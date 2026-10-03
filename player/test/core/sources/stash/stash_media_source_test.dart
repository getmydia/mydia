import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/stash/stash_client.dart';
import 'package:player/core/sources/stash/stash_mapping.dart';
import 'package:player/core/sources/stash/stash_media_source.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/source_error.dart';

import '../fixed_connection.dart';
import '../media_source_contract.dart';
import 'fake_stash_server.dart';

final stashRecord = SourceAccountRecord(
  account: const ProviderAccount(
    id: 'st1',
    kind: SourceKind.stash,
    displayName: 'Shelf',
    storageNamespace: 'source/st1',
    activeProfileId: 'owner',
  ),
  profiles: const [
    SourceProfile(id: 'owner', accountId: 'st1', name: 'Owner', isOwner: true),
  ],
  servers: [
    SourceServer(
      id: 'main',
      accountId: 'st1',
      profileId: 'owner',
      name: 'Shelf',
      connections: [ServerConnection(uri: FakeStashServer.base, local: true)],
    ),
  ],
  addedAtMs: 0,
);

({StashMediaSource source, FakeStashServer server, List<int> unauthorized})
    build() {
  final server = FakeStashServer();
  final unauthorized = <int>[];
  final source = StashMediaSource(
    source: stashRecord.sources.single,
    client: StashClient(
      connection: FixedConnection(FakeStashServer.base),
      http: SourceHttp(client: server.client),
      apiKey: () async => FakeStashServer.apiKey,
      onUnauthorized: () => unauthorized.add(1),
    ),
  );
  return (source: source, server: server, unauthorized: unauthorized);
}

void main() {
  const sid = SourceId('st1:owner:main');

  runMediaSourceContract(
      'Stash',
      () async => ContractFixture(
            source: build().source,
            library: const LibraryRef(sourceId: sid, id: stashScenesLibraryId),
            playable: const ItemRef(
                sourceId: sid, kind: ItemKind.video, externalId: '2'),
            libraryItemCount: 5,
          ));

  test('strips the API key from server-made URLs', () {
    expect(
      stashRelativePath(
          'http://192.168.1.20:9999/scene/4/screenshot?t=1700&apikey=k'),
      '/scene/4/screenshot?t=1700',
    );
    expect(stashRelativePath(null), isNull);
  });

  test('pages by page number with Stash sort names', () async {
    final b = build();
    await b.source.browse(
      const LibraryRef(sourceId: sid, id: stashScenesLibraryId),
      const BrowseQuery(sortId: 'date', filterIds: {'unplayed'}, pageSize: 2),
      cursor: const Cursor('2'),
    );
    final (name, vars) = b.server.operations.last;
    expect(name, 'FindScenes');
    expect(vars['filter'], {
      'page': 2,
      'per_page': 2,
      'sort': 'date',
      'direction': 'DESC',
    });
    expect(vars['scene_filter'], {
      'play_count': {'value': 0, 'modifier': 'EQUALS'},
    });
  });

  test('falls back to the file name for an untitled scene', () async {
    final page = await build().source.browse(
        const LibraryRef(sourceId: sid, id: stashScenesLibraryId),
        const BrowseQuery());
    expect(page.items[2].title, 'tidepool_3.mp4');
  });

  test('maps a scene with its file, captions and people', () async {
    final detail = await build().source.item(
        const ItemRef(sourceId: sid, kind: ItemKind.video, externalId: '2'));
    expect(detail.summary.userState.watched, isTrue);
    expect(detail.summary.userState.progressSeconds, 300);
    expect(detail.studio, 'Kelpline');
    expect(detail.people, ['Oona Marsh']);
    expect(detail.rating, 8.0);
    final version = detail.versions.single;
    expect(version.id, '92');
    expect(version.height, 1080);
    expect(version.bitrateKbps, 6000);
    expect(version.streamPath, '/scene/2/stream');
    expect(version.streams.single.externalPath,
        '/scene/2/caption?lang=en&type=srt');
  });

  test('watched writes add a play or reset the count', () async {
    final b = build();
    const ref = ItemRef(sourceId: sid, kind: ItemKind.video, externalId: '2');
    await b.source.as<WatchedState>()!.setWatched(ref, true);
    expect(b.server.operations.last.$1, 'AddPlay');
    await b.source.as<WatchedState>()!.setWatched(ref, false);
    expect(b.server.operations.last.$1, 'ResetPlayCount');
  });

  test('a schema without a field is unsupported, not a crash', () async {
    final b = build();
    b.server.graphqlError =
        'Cannot query field "sceneAddPlay" on type "Mutation".';
    await expectLater(
      b.source.as<WatchedState>()!.setWatched(
          const ItemRef(sourceId: sid, kind: ItemKind.video, externalId: '2'),
          true),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.unsupported)),
    );
  });

  test('a rejected key reports unauthorized', () async {
    final b = build();
    b.server.status = 401;
    await expectLater(b.source.libraries(), completes,
        reason: 'the synthetic library needs no request');
    await expectLater(
      b.source.browse(const LibraryRef(sourceId: sid, id: stashScenesLibraryId),
          const BrowseQuery()),
      throwsA(isA<SourceException>()),
    );
    expect(b.unauthorized, [1]);
  });

  test('artwork resolves against the base with the key in a header', () async {
    final request = await build()
        .source
        .artwork(const ArtworkRef('/scene/4/screenshot?t=1700'), width: 300);
    expect(request!.url, 'http://192.168.1.20:9999/scene/4/screenshot?t=1700');
    expect(request.headers['ApiKey'], FakeStashServer.apiKey);
  });

  test('checkStatus passes on OK', () async {
    await build().source.client.checkStatus();
  });
}
