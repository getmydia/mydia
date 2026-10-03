import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/jellyfin/jellyfin_client.dart';
import 'package:player/core/sources/jellyfin/jellyfin_media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

import '../fixed_connection.dart';
import '../media_source_contract.dart';
import 'fake_jellyfin_server.dart';
import 'jellyfin_client_test.dart' show identity;

final jellyfinRecord = SourceAccountRecord(
  account: const ProviderAccount(
    id: 'jf1',
    kind: SourceKind.jellyfin,
    displayName: FakeJellyfinServer.username,
    storageNamespace: 'source/jf1',
    activeProfileId: FakeJellyfinServer.userId,
  ),
  profiles: const [
    SourceProfile(
        id: FakeJellyfinServer.userId,
        accountId: 'jf1',
        name: FakeJellyfinServer.username,
        isOwner: true),
  ],
  servers: [
    SourceServer(
      id: FakeJellyfinServer.serverId,
      accountId: 'jf1',
      profileId: FakeJellyfinServer.userId,
      name: 'Harbor',
      connections: [ServerConnection(uri: FakeJellyfinServer.base)],
    ),
  ],
  addedAtMs: 0,
);

const jellyfinSid =
    SourceId('jf1:${FakeJellyfinServer.userId}:${FakeJellyfinServer.serverId}');

({
  JellyfinMediaSource source,
  FakeJellyfinServer server,
  List<int> unauthorized
}) build() {
  final server = FakeJellyfinServer();
  final unauthorized = <int>[];
  final source = JellyfinMediaSource(
    source: jellyfinRecord.sources.single,
    client: JellyfinClient(
      connection: FixedConnection(FakeJellyfinServer.base),
      http: SourceHttp(client: server.client),
      identity: () async => identity,
      token: () async => FakeJellyfinServer.token,
      userId: FakeJellyfinServer.userId,
      onUnauthorized: () => unauthorized.add(1),
    ),
  );
  return (source: source, server: server, unauthorized: unauthorized);
}

void main() {
  runMediaSourceContract(
      'Jellyfin',
      () async => ContractFixture(
            source: build().source,
            library: const LibraryRef(sourceId: jellyfinSid, id: 'lib-movies'),
            playable: const ItemRef(
                sourceId: jellyfinSid, kind: ItemKind.movie, externalId: 'm2'),
            libraryItemCount: 5,
          ));

  test('lists film and show libraries, not music', () async {
    final libraries = await build().source.libraries();
    expect(libraries.map((l) => (l.ref.id, l.kind)), [
      ('lib-movies', LibraryKind.movies),
      ('lib-shows', LibraryKind.shows),
    ]);
  });

  test('browse sends the per-user, recursive, sorted query', () async {
    final b = build();
    await b.source.browse(
      const LibraryRef(sourceId: jellyfinSid, id: 'lib-movies'),
      const BrowseQuery(
          pageSize: 2,
          sortId: 'DateCreated',
          filterIds: {'IsUnplayed', 'bogus'}),
      cursor: const Cursor('2'),
    );
    final q = b.server.requests.last.url.queryParameters;
    expect(q['userId'], FakeJellyfinServer.userId);
    expect(q['ParentId'], 'lib-movies');
    expect(q['IncludeItemTypes'], 'Movie');
    expect(q['Recursive'], 'true');
    expect(q['StartIndex'], '2');
    expect(q['Limit'], '2');
    expect(q['SortBy'], 'DateCreated,SortName');
    expect(q['SortOrder'], 'Descending');
    expect(q['Filters'], 'IsUnplayed',
        reason: 'unknown filter ids are dropped');
  });

  test('a show library browses series', () async {
    final b = build();
    final page = await b.source.browse(
        const LibraryRef(sourceId: jellyfinSid, id: 'lib-shows'),
        const BrowseQuery(pageSize: 20));
    expect(b.server.requests.last.url.queryParameters['IncludeItemTypes'],
        'Series');
    expect(page.items.single.ref.kind, ItemKind.show);
  });

  test('show to seasons to episodes', () async {
    final b = build();
    final seasons = await b.source.children(const ItemRef(
        sourceId: jellyfinSid, kind: ItemKind.show, externalId: 'show1'));
    expect(seasons.items.single.ref.externalId, 'season1');
    final episodes = await b.source.children(seasons.items.single.ref);
    expect(episodes.items.map((e) => e.index), [1, 2]);
    final q = b.server.requests.last.url.queryParameters;
    expect(q['ParentId'], 'season1');
    expect(q['IncludeItemTypes'], 'Episode');
  });

  test('seasons come in one page; a later cursor adds nothing', () async {
    final b = build();
    const show = ItemRef(
        sourceId: jellyfinSid, kind: ItemKind.show, externalId: 'show1');
    final first = await b.source.children(show);
    expect(first.nextCursor, isNull);
    final requests = b.server.requests.length;
    final later = await b.source.children(show, cursor: const Cursor('200'));
    expect(later.items, isEmpty);
    expect(later.nextCursor, isNull);
    expect(b.server.requests.length, requests,
        reason: 'the server would answer the same seasons again');
  });

  test('a movie has no children', () async {
    final page = await build().source.children(const ItemRef(
        sourceId: jellyfinSid, kind: ItemKind.movie, externalId: 'm1'));
    expect(page.items, isEmpty);
  });

  test('search finds by name', () async {
    final results = await build().source.search('Bay 3');
    expect(results.single.title, 'Lantern Bay 3');
  });

  test('watched marks and unmarks with the user id', () async {
    final b = build();
    const ref =
        ItemRef(sourceId: jellyfinSid, kind: ItemKind.movie, externalId: 'm1');
    await b.source.setWatched(ref, true);
    await b.source.setWatched(ref, false);
    expect(b.server.requests.map((r) => '${r.method} ${r.url.path}'),
        ['POST /UserPlayedItems/m1', 'DELETE /UserPlayedItems/m1']);
    expect(b.server.requests.last.url.queryParameters['userId'],
        FakeJellyfinServer.userId);
  });

  test('artwork asks for the width and keys on the tagged path', () async {
    final request = await build().source.artwork(
        const ArtworkRef('/Items/m2/Images/Primary?tag=p2'),
        width: 300);
    final url = Uri.parse(request!.url);
    expect(url.path, '/Items/m2/Images/Primary');
    expect(url.queryParameters['tag'], 'p2');
    expect(url.queryParameters['fillWidth'], '300');
    expect(
        request.cacheKey, '$jellyfinSid|/Items/m2/Images/Primary?tag=p2|300');
  });
}
