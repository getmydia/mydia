import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/plex/plex_identity.dart';
import 'package:player/core/sources/plex/plex_media_source.dart';
import 'package:player/core/sources/plex/plex_server_client.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/source_http.dart';
import 'package:player/domain/models/download_plan.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/source_error.dart';

import '../fixed_connection.dart';
import '../media_source_contract.dart';
import '../store/source_json_test.dart' show plexRecord;
import 'fake_plex_server.dart';

const identity = PlexIdentity(
  clientIdentifier: 'cid',
  version: '1',
  platform: 'Linux',
);

({
  PlexMediaSource source,
  FakePlexServer server,
  FixedConnection connection,
  List<int> unauthorized,
}) build() {
  final server = FakePlexServer();
  final connection = FixedConnection(FakePlexServer.base);
  final unauthorized = <int>[];
  final source = PlexMediaSource(
    source: plexRecord().sources.single,
    client: PlexServerClient(
      connection: connection,
      http: SourceHttp(client: server.client),
      identity: () async => identity,
      token: () async => FakePlexServer.token,
      onUnauthorized: () => unauthorized.add(1),
    ),
  );
  return (
    source: source,
    server: server,
    connection: connection,
    unauthorized: unauthorized,
  );
}

void main() {
  const sid = SourceId('acc1:owner:abc123');

  runMediaSourceContract('Plex', () async {
    final b = build();
    return ContractFixture(
      source: b.source,
      library: const LibraryRef(sourceId: sid, id: '1'),
      playable: const ItemRef(
        sourceId: sid,
        kind: ItemKind.movie,
        externalId: '101',
      ),
      libraryItemCount: FakePlexServer.movies.length,
      show:
          const ItemRef(sourceId: sid, kind: ItemKind.show, externalId: '201'),
    );
  });

  const movie = ItemRef(sourceId: sid, kind: ItemKind.movie, externalId: '101');

  const episode =
      ItemRef(sourceId: sid, kind: ItemKind.episode, externalId: '401');

  test('skip segments come from the episode markers', () async {
    final b = build();
    b.server.markers = [
      {'type': 'intro', 'startTimeOffset': 1000, 'endTimeOffset': 61000},
    ];
    final segments = await b.source.as<SkipSegments>()!.skipSegments(episode);
    expect(segments.single.endMs, 61000);
    expect(b.server.requests.last.url.queryParameters['includeMarkers'], '1');
  });

  test('an item with no markers has no segments', () async {
    final segments =
        await build().source.as<SkipSegments>()!.skipSegments(episode);
    expect(segments, isEmpty);
  });

  test('item detail carries cast, content rating and parents', () async {
    final source = build().source;
    final detail = await source.item(movie);
    expect(detail.contentRating, 'PG');
    expect(detail.cast.single.name, 'Ana Bergström');
    expect(detail.cast.single.role, 'Kira Solt');
    expect(detail.cast.single.photo, isNotNull);

    final page = await source.children(
      const ItemRef(sourceId: sid, kind: ItemKind.season, externalId: '301'),
    );
    expect(page.items.first.overview, 'An invented episode.');
    expect(page.items.first.airDate, '2024-01-01');
    expect(page.items.first.defaultVersionId, '501');

    final episode = await source.item(
      const ItemRef(sourceId: sid, kind: ItemKind.episode, externalId: '401'),
    );
    expect(episode.show?.externalId, '201');
    expect(episode.show?.kind, ItemKind.show);
    expect(episode.season?.externalId, '301');
    expect(episode.season?.kind, ItemKind.season);
  });

  test('similar lists the server picks', () async {
    final similar = await build().source.as<Similar>()!.similar(movie);
    expect(similar.map((i) => i.ref.externalId), ['102', '103']);
  });

  test('recently added asks Plex for 20 and keeps its order', () async {
    final b = build();
    final items = await b.source.recentlyAdded();
    expect(items.map((i) => i.ref.externalId), ['104', '102']);
    final request = b.server.requests
        .lastWhere((r) => r.url.path == '/library/recentlyAdded');
    expect(request.url.queryParameters['X-Plex-Container-Size'], '20');
  });

  test('next up reads the show on deck', () async {
    final next = await build().source.as<NextUp>()!.nextUp(
          const ItemRef(sourceId: sid, kind: ItemKind.show, externalId: '201'),
        );
    expect(next?.ref.externalId, '402');
  });

  test('a show with nothing on deck has no next up', () async {
    final b = build();
    b.server.nothingOnDeck = true;
    final next = await b.source.as<NextUp>()!.nextUp(
          const ItemRef(sourceId: sid, kind: ItemKind.show, externalId: '201'),
        );
    expect(next, isNull);
  });

  test('a missing similar endpoint reads as none', () async {
    final similar = await build().source.as<Similar>()!.similar(
          const ItemRef(sourceId: sid, kind: ItemKind.movie, externalId: '105'),
        );
    expect(similar, isEmpty);
  });

  test('lists movie and show sections, not music', () async {
    final libraries = await build().source.libraries();
    expect([for (final l in libraries) l.title], ['Films', 'Series']);
    expect(libraries.last.kind, LibraryKind.shows);
  });

  test('paging a library fetches the sections once', () async {
    final b = build();
    const library = LibraryRef(sourceId: sid, id: '1');
    const query = BrowseQuery(pageSize: 2);
    final first = await b.source.browse(library, query);
    await b.source.browse(library, query, cursor: first.nextCursor);
    final sectionCalls = b.server.requests
        .where((r) => r.url.path == '/library/sections')
        .length;
    expect(sectionCalls, 1);

    // libraries() refreshes what browse reuses.
    await b.source.libraries();
    expect(b.server.requests.where((r) => r.url.path == '/library/sections'),
        hasLength(2));
  });

  test('sends sort, filter and paging as Plex expects', () async {
    final b = build();
    await b.source.browse(
      const LibraryRef(sourceId: sid, id: '1'),
      const BrowseQuery(
          sortId: 'addedAt', filterIds: {'unwatched'}, pageSize: 2),
    );
    final q = b.server.requests.last.url.queryParameters;
    expect(q['sort'], 'addedAt:desc');
    expect(q['unwatched'], '1');
    expect(q['type'], '1');
    expect(q['X-Plex-Container-Size'], '2');
    expect(
      b.server.requests.last.url.query,
      isNot(contains(FakePlexServer.token)),
    );
  });

  test('maps a movie with versions, streams and people', () async {
    final detail = await build().source.item(
          const ItemRef(sourceId: sid, kind: ItemKind.movie, externalId: '101'),
        );
    expect(detail.summary.title, 'The Lantern Keeper');
    expect(detail.overview, startsWith('A keeper'));
    expect(detail.genres, ['Drama']);
    expect(detail.people, ['Ana Bergström']);
    final version = detail.versions.single;
    expect(version.id, '21');
    expect(version.streamPath, '/library/parts/21/1700000000/file.mkv');
    expect(version.durationSeconds, 5400);
    expect(version.bitrateKbps, 8000);
    final subs = version.streams.where(
      (s) => s.kind == MediaStreamKind.subtitle,
    );
    expect(subs.first.externalPath, '/library/streams/33');
    expect(subs.last.externalPath, isNull);
  });

  test('resolves the original file with the token in a header', () async {
    final plan = await build().source.resolve(movie, 'original') as DirectFile;
    expect(Uri.parse(plan.url).path, '/library/parts/21/1700000000/file.mkv');
    expect(plan.headers['X-Plex-Token'], FakePlexServer.token);
    expect(plan.url, isNot(contains(FakePlexServer.token)));
    expect(plan.extension, 'mkv');
  });

  test('walks show, season, episodes', () async {
    final b = build();
    final seasons = await b.source.children(
      const ItemRef(sourceId: sid, kind: ItemKind.show, externalId: '201'),
    );
    expect(seasons.items.single.ref.kind, ItemKind.season);
    final episodes = await b.source.children(seasons.items.single.ref);
    expect(episodes.items.map((e) => e.title), ['First Light', 'Fog Bank']);
    expect(episodes.items.first.userState.watched, isTrue);
    expect(episodes.items.last.userState.progressSeconds, 600);
    expect(episodes.items.last.subtitle, 'S1 · E2');
  });

  test('searches movies, shows and episodes only', () async {
    final results = await build().source.as<Searchable>()!.search('salt');
    expect(results.single.title, 'Saltwater Clocks');
  });

  test('marks watched and unwatched', () async {
    final b = build();
    const ref = ItemRef(
      sourceId: sid,
      kind: ItemKind.movie,
      externalId: '101',
    );
    await b.source.as<WatchedState>()!.setWatched(ref, true);
    expect(b.server.requests.last.url.path, '/:/scrobble');
    expect(b.server.requests.last.url.queryParameters['key'], '101');
    await b.source.as<WatchedState>()!.setWatched(ref, false);
    expect(b.server.requests.last.url.path, '/:/unscrobble');
  });

  test(
    'artwork goes through the photo transcoder with the token in a header',
    () async {
      final request = await build().source.artwork(
            const ArtworkRef('/library/metadata/101/thumb/1700'),
            width: 300,
          );
      final url = Uri.parse(request!.url);
      expect(url.path, '/photo/:/transcode');
      expect(url.queryParameters['url'], '/library/metadata/101/thumb/1700');
      expect(url.queryParameters['width'], '300');
      expect(request.headers['X-Plex-Token'], FakePlexServer.token);
      expect(request.cacheKey, '$sid|/library/metadata/101/thumb/1700|300');
    },
  );

  test('a 401 reports unauthorized once and throws', () async {
    final b = build();
    b.server.status = 401;
    await expectLater(b.source.libraries(), throwsA(isA<SourceException>()));
    expect(b.unauthorized, [1]);
  });

  test('an HTTP error status does not report the connection', () async {
    final b = build();
    b.server.status = 599;
    await expectLater(b.source.libraries(), throwsA(isA<SourceException>()));
    expect(
      b.connection.failures,
      isEmpty,
      reason: 'an HTTP error is an answer, not a dead connection',
    );
  });

  test('a transport failure reports the base to the connection', () async {
    final b = build();
    b.server.throwTransport = true;
    await expectLater(
      b.source.libraries(),
      throwsA(
        isA<SourceException>().having(
          (e) => e.kind,
          'kind',
          SourceErrorKind.unreachable,
        ),
      ),
    );
    expect(b.connection.failures, [FakePlexServer.base]);
  });

  group('home', () {
    test('declares Continue Watching and hubs', () {
      final caps = build().source.capabilities;
      expect(caps, contains(SourceCapability.continueWatching));
      expect(caps, contains(SourceCapability.hubs));
    });

    test('Continue Watching maps the flat list, capped at 20', () async {
      final b = build();
      final items = await b.source.continueWatching();
      expect(items.map((i) => i.ref.externalId), ['402', '103']);
      final q = b.server.requests.last.url.queryParameters;
      expect(b.server.requests.last.url.path, '/hubs/continueWatching/items');
      expect(q['X-Plex-Container-Size'], '20');
    });

    test('an episode carries its show title, the show poster and its still',
        () async {
      final episode = (await build().source.continueWatching()).first;
      expect(episode.showTitle, 'Harbour Lights');
      expect(episode.subtitle, 'S1 · E2');
      expect(episode.userState.progressSeconds, 600);
      expect(episode.poster, const ArtworkRef('/library/metadata/201/thumb/1'));
      expect(
          episode.backdrop, const ArtworkRef('/library/metadata/402/thumb/1'));
    });

    test('hubs drop Continue Watching, On Deck, music and empty hubs',
        () async {
      final hubs = await build().source.hubs();
      expect(
          hubs.map((h) => h.id), ['home.movies.recent', 'home.mixed.released']);
      expect(hubs.first.title, 'Recently Added in Films');
      expect(hubs.first.items.map((i) => i.ref.externalId), ['104', '105']);
    });

    test('hubs cap each row at 20 and drop a repeated hub id', () async {
      final b = build();
      b.server.crowdedHubs = true;
      final hubs = await b.source.hubs();
      expect(hubs.map((h) => h.id).toSet().length, hubs.length);
      expect(hubs.map((h) => h.id), contains('home.movies.long'));
      expect(hubs.firstWhere((h) => h.id == 'home.movies.long').items,
          hasLength(20));
      expect(hubs.first.title, 'Recently Added in Films');
      expect(hubs.first.items.map((i) => i.ref.externalId), ['104', '105']);
    });

    test('a hub links to its library only when every item shares it', () async {
      final hubs = await build().source.hubs();
      expect(hubs.first.library, const LibraryRef(sourceId: sid, id: '1'));
      expect(hubs.last.library, isNull);
    });

    test('remove sends a PUT with the rating key', () async {
      final b = build();
      await b.source.removeFromContinueWatching(
        const ItemRef(sourceId: sid, kind: ItemKind.episode, externalId: '402'),
      );
      final request = b.server.requests.last;
      expect(request.method, 'PUT');
      expect(request.url.path, '/actions/removeFromContinueWatching');
      expect(request.url.queryParameters['ratingKey'], '402');
    });

    test('every Continue Watching entry can be removed', () async {
      final source = build().source;
      final items = await source.continueWatching();
      expect(items, isNotEmpty);
      expect(items.every(source.canRemoveFromContinueWatching), isTrue);
    });
  });
}
