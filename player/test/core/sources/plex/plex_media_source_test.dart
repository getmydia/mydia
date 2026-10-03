import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/plex/plex_identity.dart';
import 'package:player/core/sources/plex/plex_media_source.dart';
import 'package:player/core/sources/plex/plex_server_client.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/source_http.dart';
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
    );
  });

  test('lists movie and show sections, not music', () async {
    final libraries = await build().source.libraries();
    expect([for (final l in libraries) l.title], ['Films', 'Series']);
    expect(libraries.last.kind, LibraryKind.shows);
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
    expect(detail.people, ['Ines Varga']);
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
}
