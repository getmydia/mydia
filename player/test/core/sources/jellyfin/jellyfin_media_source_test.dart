import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/jellyfin/jellyfin_client.dart';
import 'package:player/core/sources/jellyfin/jellyfin_media_source.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/source_error.dart';

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

  group('Continue Watching', () {
    const ticks = FakeJellyfinServer.ticks;
    Map<String, dynamic> resumingEpisode(int n) => {
          ...FakeJellyfinServer.episode(n),
          'UserData': {'Played': false, 'PlaybackPositionTicks': 600 * ticks},
        };
    Map<String, dynamic> otherSeries(int n) => {
          ...FakeJellyfinServer.episode(n),
          'Id': 'o$n',
          'SeriesId': 'show2',
          'SeriesName': 'Driftwood',
        };

    test('declares the capability', () {
      final source = build().source;
      expect(source.capabilities, contains(SourceCapability.continueWatching));
      expect(source.as<ContinueWatching>(), same(source));
    });

    test('asks for resumable video and next episodes, for this user', () async {
      final b = build();
      await b.source.continueWatching();
      final byPath = {
        for (final r in b.server.requests) r.url.path: r.url.queryParameters,
      };
      expect(byPath['/UserItems/Resume'], {
        'userId': FakeJellyfinServer.userId,
        'MediaTypes': 'Video',
        'Limit': '20',
        'EnableImageTypes': 'Primary,Backdrop,Thumb',
      });
      expect(byPath['/Shows/NextUp'], {
        'userId': FakeJellyfinServer.userId,
        'Limit': '20',
        'enableResumable': 'false',
        'enableRewatching': 'false',
        'EnableImageTypes': 'Primary,Backdrop,Thumb',
      });
    });

    test('resume entries first, then next episodes of other shows', () async {
      final b = build();
      b.server
        ..resumeItems = [
          FakeJellyfinServer.movie(3, positionSeconds: 300),
          resumingEpisode(2),
        ]
        // e3 is Saltmarsh, which already has a resume card.
        ..nextUpItems = [FakeJellyfinServer.episode(3), otherSeries(1)];
      final items = await b.source.continueWatching();
      expect(items.map((i) => i.ref.externalId), ['m3', 'e2', 'o1']);
      expect(items[1].showTitle, 'Saltmarsh');
      expect(items[1].subtitle, 'S1 · E2');
    });

    test('holds at most 20 entries', () async {
      final b = build();
      b.server
        ..resumeItems = [
          for (var n = 1; n <= 15; n++)
            FakeJellyfinServer.movie(n, positionSeconds: 60),
        ]
        ..nextUpItems = [for (var n = 1; n <= 10; n++) otherSeries(n)];
      final items = await b.source.continueWatching();
      expect(items, hasLength(20));
      expect(items.last.ref.externalId, 'o5');
    });

    for (final path in ['/UserItems/Resume', '/Shows/NextUp']) {
      test('fails when $path fails', () async {
        final b = build();
        b.server.failing.add(path);
        await expectLater(
            b.source.continueWatching(), throwsA(isA<SourceException>()));
      });
    }

    test('only an entry with a resume point can be removed', () async {
      final b = build();
      b.server
        ..resumeItems = [FakeJellyfinServer.movie(3, positionSeconds: 300)]
        ..nextUpItems = [otherSeries(1)];
      final [resume, nextUp] = await b.source.continueWatching();
      expect(b.source.canRemoveFromContinueWatching(resume), isTrue);
      expect(b.source.canRemoveFromContinueWatching(nextUp), isFalse);
    });

    test('remove clears the resume point for this user', () async {
      final b = build();
      await b.source.removeFromContinueWatching(const ItemRef(
          sourceId: jellyfinSid, kind: ItemKind.movie, externalId: 'm3'));
      final request = b.server.requests.last;
      expect(request.method, 'POST');
      expect(request.url.path, '/UserItems/m3/UserData');
      expect(request.url.queryParameters['userId'], FakeJellyfinServer.userId);
      final (path, body) = b.server.bodies.last;
      expect(path, '/UserItems/m3/UserData');
      expect(body, {'PlaybackPositionTicks': 0});
    });
  });

  test('similar, next up and favorites call the right endpoints', () async {
    final b = build();
    b.server.nextUpItems = [FakeJellyfinServer.episode(2)];
    const movie =
        ItemRef(sourceId: jellyfinSid, kind: ItemKind.movie, externalId: 'm1');
    const show = ItemRef(
        sourceId: jellyfinSid, kind: ItemKind.show, externalId: 'show1');
    expect(
        b.source.capabilities,
        containsAll([
          SourceCapability.similar,
          SourceCapability.favorites,
          SourceCapability.nextUp,
        ]));
    expect(await b.source.as<Similar>()!.similar(movie), hasLength(2));
    final next = await b.source.as<NextUp>()!.nextUp(show);
    expect(next?.ref.kind, ItemKind.episode);
    expect(b.server.requests.last.url.queryParameters['seriesId'], 'show1');
    expect(
        await b.source.as<NextUp>()!.nextUp(const ItemRef(
            sourceId: jellyfinSid, kind: ItemKind.show, externalId: 'other')),
        isNull);
    await b.source.as<Favorites>()!.setFavorite(movie, true);
    await b.source.as<Favorites>()!.setFavorite(movie, false);
    expect(b.server.favoriteCalls, [('POST', 'm1'), ('DELETE', 'm1')]);
  });

  test('season children ask for overviews', () async {
    final b = build();
    await b.source.children(const ItemRef(
        sourceId: jellyfinSid, kind: ItemKind.season, externalId: 'season1'));
    expect(b.server.requests.last.url.queryParameters['Fields'], 'Overview');
  });
}
