import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/mydia/mydia_guest_client.dart';
import 'package:player/core/sources/mydia/mydia_guest_credentials.dart';
import 'package:player/core/sources/mydia/mydia_guest_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

import '../media_source_contract.dart';
import 'fake_mydia_transport.dart';
import 'mydia_fixtures.dart' as fx;

const sid = SourceId(fx.sid);

const guest = Source(
  account: ProviderAccount(
    id: 'mguest',
    kind: SourceKind.mydia,
    displayName: 'Lakeside',
    storageNamespace: 'source/mguest',
    activeProfileId: 'owner',
  ),
  profile: SourceProfile(
      id: 'owner', accountId: 'mguest', name: 'Owner', isOwner: true),
  server: SourceServer(
      id: 'inst-2', accountId: 'mguest', profileId: 'owner', name: 'Lakeside'),
);

({MydiaGuestSource source, FakeMydiaTransport t}) build() {
  final t = FakeMydiaTransport();
  final movies = [for (var i = 1; i <= 5; i++) fx.movie('m-$i')];
  t.handlers['GuestMovies'] = (v) {
    final first = v['first'] as int;
    final start = v['after'] == null ? 0 : int.parse(v['after'] as String);
    final page = movies.skip(start).take(first).toList();
    final end = start + page.length;
    return {
      'movies': {
        'edges': [
          for (final m in page) {'node': m}
        ],
        'pageInfo': {'hasNextPage': end < movies.length, 'endCursor': '$end'},
        'totalCount': movies.length,
      }
    };
  };
  t.handlers['GuestTvShows'] = (_) => {
        'tvShows': {
          'edges': [
            {'node': fx.show('s-1')}
          ],
          'pageInfo': {'hasNextPage': false, 'endCursor': null},
          'totalCount': 1,
        }
      };
  t.handlers['MovieDetail'] = (v) => {'movie': fx.movie(v['id'] as String)};
  t.handlers['TvShowDetail'] = (v) => {'tvShow': fx.show(v['id'] as String)};
  t.handlers['EpisodeDetail'] =
      (v) => {'episode': fx.episode(v['id'] as String)};
  t.handlers['SeasonEpisodes'] = (v) => {
        'seasonEpisodes': [
          fx.episode('e-21', number: 1),
          fx.episode('e-22', number: 2)
        ]
      };
  t.handlers['Search'] = (_) => {
        'search': {
          'totalCount': 2,
          'sections': [
            {
              'type': 'MOVIE',
              'totalCount': 1,
              'results': [
                {
                  'id': 'm-1',
                  'type': 'MOVIE',
                  'title': 'A',
                  'year': 2020,
                  'artwork': null
                }
              ]
            },
            {
              'type': 'EPISODE',
              'totalCount': 1,
              'results': [
                {'id': 'e-1', 'type': 'EPISODE', 'title': 'B', 'parentId': null}
              ]
            },
          ]
        }
      };
  t.handlers['GuestContinueWatching'] = (_) => {'continueWatching': <Object>[]};
  for (final op in [
    'MarkMovieWatched',
    'MarkMovieUnwatched',
    'MarkEpisodeWatched',
    'MarkEpisodeUnwatched',
    'MarkSeasonWatched',
    'MarkSeasonUnwatched',
    'ToggleFavorite',
    'RemoveFromContinueWatching'
  ]) {
    t.handlers[op] = (_) => <String, dynamic>{};
  }
  final client = MydiaGuestClient(
    transport: t,
    load: () async => const MydiaGuestCredentials(
        instanceId: 'inst-2', accessToken: 'access'),
    save: (_) async {},
    onUnauthorized: () {},
  );
  return (source: MydiaGuestSource(source: guest, client: client), t: t);
}

void main() {
  test('the fixture source id matches the record shape', () {
    expect(guest.id, sid);
  });

  runMediaSourceContract('Guest Mydia', () async {
    final b = build();
    return ContractFixture(
      source: b.source,
      library: const LibraryRef(sourceId: sid, id: 'movies'),
      playable:
          const ItemRef(sourceId: sid, kind: ItemKind.movie, externalId: 'm-2'),
      libraryItemCount: 5,
      show:
          const ItemRef(sourceId: sid, kind: ItemKind.show, externalId: 's-1'),
    );
  });

  test('browse sends the sort the viewer picked', () async {
    final b = build();
    await b.source.browse(const LibraryRef(sourceId: sid, id: 'movies'),
        const BrowseQuery(pageSize: 2, sortId: 'YEAR'));
    expect(b.t.calls.last.vars['sort'], {'field': 'YEAR', 'direction': 'DESC'});
  });

  test('a season is the show detail seasons; its children are the episodes',
      () async {
    final b = build();
    final seasons = await b.source.children(
        const ItemRef(sourceId: sid, kind: ItemKind.show, externalId: 's-1'));
    expect(seasons.items.map((s) => s.ref.externalId), ['s-1.s1', 's-1.s2']);
    final episodes = await b.source.children(seasons.items.last.ref);
    expect(b.t.calls.last.vars, {'showId': 's-1', 'seasonNumber': 2});
    expect(episodes.items.map((e) => e.index), [1, 2]);
  });

  test('marking a season sends one mutation; a show marks each season',
      () async {
    final b = build();
    await b.source.setWatched(
        const ItemRef(
            sourceId: sid, kind: ItemKind.season, externalId: 's-1.s2'),
        true);
    expect(b.t.calls.last.operation, 'MarkSeasonWatched');
    b.t.calls.clear();
    await b.source.setWatched(
        const ItemRef(sourceId: sid, kind: ItemKind.show, externalId: 's-1'),
        false);
    expect(b.t.calls.where((c) => c.operation == 'MarkSeasonUnwatched'),
        hasLength(2));
  });

  test('favorite toggles only when the state differs', () async {
    final b = build();
    const ref = ItemRef(sourceId: sid, kind: ItemKind.movie, externalId: 'm-1');
    await b.source
        .setFavorite(ref, true); // fixture movie is already a favorite
    expect(b.t.calls.where((c) => c.operation == 'ToggleFavorite'), isEmpty);
    await b.source.setFavorite(ref, false);
    expect(
        b.t.calls.where((c) => c.operation == 'ToggleFavorite'), hasLength(1));
  });

  test('search drops episode results it cannot place', () async {
    final results = await build().source.search('a');
    expect(results.map((r) => r.ref.externalId), ['m-1']);
  });

  test('artwork from the server is fetched as is, with no credential',
      () async {
    final b = build();
    final req = await b.source
        .artwork(const ArtworkRef('https://img.example/p.jpg'), width: 300);
    expect(req!.url, 'https://img.example/p.jpg');
    expect(req.headers, isEmpty);
    expect(req.cacheKey, '${sid.value}|https://img.example/p.jpg|300');
    expect(
        await b.source.artwork(const ArtworkRef('/relative.jpg'), width: 300),
        isNull);
  });

  test('declares the capabilities it implements', () {
    final s = build().source;
    expect(s.as<WatchedState>(), isNotNull);
    expect(s.as<Favorites>(), isNotNull);
    expect(s.as<NextUp>(), isNotNull);
    expect(s.as<HomeHubs>(), isNull);
  });
}
