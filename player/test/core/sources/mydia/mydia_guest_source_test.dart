import 'package:flutter/foundation.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/mydia/mydia_guest_client.dart';
import 'package:player/core/sources/mydia/mydia_guest_credentials.dart';
import 'package:player/core/sources/mydia/mydia_guest_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/models/media_segment.dart';
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

({MydiaGuestSource source, FakeMydiaTransport t}) build(
    {void Function()? onDispose}) {
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
  t.handlers['GuestRecentlyAdded'] = (_) => {
        'recentlyAdded': [
          fx.recentlyAdded('m-4', addedAt: '2024-05-03T00:00:00Z'),
          fx.recentlyAdded('s-1',
              type: 'TV_SHOW', addedAt: '2024-05-02T00:00:00Z'),
          fx.recentlyAdded('m-1', addedAt: '2024-05-01T00:00:00Z'),
        ],
      };
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
  return (
    source: MydiaGuestSource(
        source: guest,
        client: client,
        proxy: () => throw StateError('no proxy in this test'),
        onDispose: onDispose),
    t: t
  );
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

  test('recently added asks for 20 and keeps the server order', () async {
    final b = build();
    final items = await b.source.recentlyAdded();
    expect(items.map((i) => i.ref.externalId), ['m-4', 's-1', 'm-1']);
    expect(b.t.calls.last.operation, 'GuestRecentlyAdded');
    expect(b.t.calls.last.vars['first'], 20);
  });

  test('browse sorts are tagged title and added only', () async {
    final libs = await build().source.libraries();
    final shared = {for (final o in libs.first.sortOptions) o.id: o.shared};
    expect(shared, {
      'TITLE': SharedSort.title,
      'ADDED_AT': SharedSort.added,
      'YEAR': null,
    });
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
    final toggles = b.t.calls.where((c) => c.operation == 'ToggleFavorite');
    expect(toggles, hasLength(1));
    expect(toggles.single.vars, {'mediaItemId': 'm-1'});
  });

  test('concurrent setFavorite calls for one item toggle once', () async {
    final b = build();
    const ref = ItemRef(sourceId: sid, kind: ItemKind.movie, externalId: 'm-1');
    var favorite = true;
    b.t.handlers['MovieDetail'] = (v) =>
        {'movie': fx.movie(v['id'] as String)..['isFavorite'] = favorite};
    b.t.handlers['ToggleFavorite'] = (_) {
      favorite = !favorite;
      return <String, dynamic>{};
    };
    await Future.wait([
      b.source.setFavorite(ref, false),
      b.source.setFavorite(ref, false),
    ]);
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

  const show = ItemRef(sourceId: sid, kind: ItemKind.show, externalId: 's-1');

  test('similar caps at 20 and never answers the show itself', () async {
    final b = build();
    b.t.handlers['TvShowDetail'] = (v) {
      final s = fx.show('s-1');
      s['similar'] = [
        {
          'id': 's-1',
          'type': 'TV_SHOW',
          'title': 'Self',
          'year': 2019,
          'artwork': null
        },
        for (var i = 0; i < 24; i++)
          {
            'id': 'x-$i',
            'type': 'TV_SHOW',
            'title': 'Other $i',
            'year': 2018,
            'artwork': null
          },
      ];
      return {'tvShow': s};
    };
    final items = await b.source.similar(show);
    expect(items, hasLength(20));
    expect(items.map((i) => i.ref), isNot(contains(show)));
    final movies = await b.source.similar(
        const ItemRef(sourceId: sid, kind: ItemKind.movie, externalId: 'm-1'));
    expect(movies, isEmpty);
  });

  test('next up is the fixture episode', () async {
    final next = await build().source.nextUp(show);
    expect(next!.ref.externalId, 'e-21');
    expect(next.ref.kind, ItemKind.episode);
    expect(next.index, 1);
    expect(next.parentIndex, 2);
    expect(next.showTitle, 'Lantern Street s-1');
  });

  test('continue watching maps movies and episodes; remove sends the id',
      () async {
    final b = build();
    b.t.handlers['GuestContinueWatching'] = (_) => {
          'continueWatching': [
            {
              'id': 'm-1',
              'type': 'MOVIE',
              'title': 'A',
              'progress': null,
              'files': <Object>[]
            },
            {
              'id': 'e-1',
              'type': 'EPISODE',
              'title': 'B',
              'showTitle': 'S',
              'seasonNumber': 1,
              'episodeNumber': 3,
              'progress': null,
              'files': <Object>[]
            },
          ]
        };
    final rows = await b.source.continueWatching();
    expect(rows.map((r) => r.ref.kind), [ItemKind.movie, ItemKind.episode]);
    expect(b.source.canRemoveFromContinueWatching(rows.first), isTrue);
    await b.source.removeFromContinueWatching(rows.last.ref);
    expect(b.t.calls.last.operation, 'RemoveFromContinueWatching');
    expect(b.t.calls.last.vars, {'mediaItemId': 'e-1'});
  });

  test('browsing an unknown library is not found', () async {
    expect(
      build().source.browse(
          const LibraryRef(sourceId: sid, id: 'nope'), const BrowseQuery()),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.notFound)),
    );
  });

  test('dispose calls onDispose', () {
    var disposed = 0;
    build(onDispose: () => disposed++).source.dispose();
    expect(disposed, 1);
  });

  test('marking a show skips a season with no number', () async {
    final b = build();
    b.t.handlers['TvShowDetail'] = (v) {
      final s = fx.show('s-1');
      s['seasons'] = <dynamic>[
        ...(s['seasons'] as List),
        <String, dynamic>{'episodeCount': 1},
      ];
      return {'tvShow': s};
    };
    await b.source.setWatched(show, true);
    expect(b.t.calls.where((c) => c.operation == 'MarkSeasonWatched'),
        hasLength(2));
  });

  group('skip segments', () {
    Map<String, dynamic> files(String root) => {
          root: {
            'id': 'x',
            'files': [
              {
                'id': 'f-1',
                'segments': [
                  {'type': 'INTRO', 'startMs': 1000, 'endMs': 61000},
                ],
              },
              {
                'id': 'f-2',
                'segments': [
                  {'type': 'CREDITS', 'startMs': 1700000, 'endMs': 1800000},
                ],
              },
            ],
          },
        };

    test('picks the playing file', () async {
      final b = build();
      b.t.handlers['EpisodeSegments'] = (_) => files('episode');
      final segments = await b.source.as<SkipSegments>()!.skipSegments(
          const ItemRef(
              sourceId: sid, kind: ItemKind.episode, externalId: 'ep-1'),
          versionId: 'f-2');
      expect(segments.single.type, SegmentType.credits);
      expect(b.t.calls.last.vars['id'], 'ep-1');
    });

    test('falls back to the first file', () async {
      final b = build();
      b.t.handlers['MovieSegments'] = (_) => files('movie');
      final segments = await b.source.as<SkipSegments>()!.skipSegments(
          const ItemRef(
              sourceId: sid, kind: ItemKind.movie, externalId: 'm-1'));
      expect(segments.single.type, SegmentType.intro);
    });

    test('an older guest server has no segments', () async {
      final b = build();
      final segments = await b.source.as<SkipSegments>()!.skipSegments(
          const ItemRef(
              sourceId: sid, kind: ItemKind.movie, externalId: 'm-1'));
      expect(segments, isEmpty);
    });

    test('a show has no segments and sends nothing', () async {
      final b = build();
      final before = b.t.calls.length;
      final segments = await b.source.as<SkipSegments>()!.skipSegments(
          const ItemRef(sourceId: sid, kind: ItemKind.show, externalId: 's-1'));
      expect(segments, isEmpty);
      expect(b.t.calls.length, before);
    });
  });

  test('an injected status wins over the client\'s', () {
    final status = ValueNotifier(SourceConnectionStatus.unreachable);
    addTearDown(status.dispose);
    final client = MydiaGuestClient(
      transport: FakeMydiaTransport(),
      load: () async => const MydiaGuestCredentials(
          instanceId: 'inst-2', accessToken: 'access'),
      save: (_) async {},
      onUnauthorized: () {},
    );
    final source =
        MydiaGuestSource(source: guest, client: client, status: status);
    addTearDown(source.dispose);

    expect(source.connection, SourceConnectionStatus.unreachable);
    expect(source.statusListenable, same(status));
    status.value = SourceConnectionStatus.remote;
    expect(source.connection, SourceConnectionStatus.remote);
  });
}
