import 'package:player/core/sources/mydia/mydia_client.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/core/sources/source.dart';

import 'fake_mydia_transport.dart';

const sid = 'mguest:owner:inst-2';

Map<String, dynamic> art(String name) => {
      'posterUrl': 'https://img.example/$name-poster.jpg',
      'backdropUrl': 'https://img.example/$name-backdrop.jpg',
      'thumbnailUrl': null,
    };

Map<String, dynamic> file(String id) => {
      'id': id,
      'resolution': '1080p',
      'codec': 'hevc',
      'audioCodec': 'eac3',
      'hdrFormat': null,
      'size': 1000,
      'bitrate': 8000000,
      'directPlaySupported': true,
      'streamUrl': null,
      'directPlayUrl': null,
      'subtitles': [
        {
          'trackId': 'sub-1',
          'language': 'en',
          'title': 'English',
          'format': 'srt',
          'embedded': false,
          'deliverable': true,
          'forced': false,
          'hearingImpaired': false,
          'url': '/api/v1/subtitles/sub-1.vtt',
        }
      ],
    };

Map<String, dynamic> recentlyAdded(String id,
        {String type = 'MOVIE', required String addedAt}) =>
    {
      'id': id,
      'type': type,
      'title': 'Invented Arrival $id',
      'year': 2024,
      'artwork': art('ra-$id'),
      'addedAt': addedAt,
    };

Map<String, dynamic> movie(String id,
        {bool watched = false,
        int position = 0,
        String addedAt = '2024-03-01T10:00:00Z'}) =>
    {
      'id': id,
      'addedAt': addedAt,
      'title': 'The Quiet Orchard $id',
      'originalTitle': null,
      'year': 2021,
      'overview': 'A beekeeper inherits a valley.',
      'runtime': 104,
      'genres': ['Drama'],
      'contentRating': 'PG',
      'rating': 7.4,
      'artwork': art(id),
      'progress': {
        'positionSeconds': position,
        'durationSeconds': 6240,
        'percentage': 0.0,
        'watched': watched,
        'lastWatchedAt':
            watched || position > 0 ? '2024-04-02T21:30:00Z' : null,
      },
      'files': [file('f-$id')],
      'isFavorite': true,
    };

Map<String, dynamic> show(String id,
        {String addedAt = '2024-03-01T10:00:00Z'}) =>
    {
      'id': id,
      'addedAt': addedAt,
      'title': 'Lantern Street $id',
      'originalTitle': null,
      'year': 2019,
      'overview': 'Neighbours keep a lighthouse running.',
      'genres': ['Comedy'],
      'contentRating': 'TV-14',
      'rating': 8.1,
      'seasonCount': 2,
      'artwork': art(id),
      'seasons': [
        {
          'seasonNumber': 1,
          'episodeCount': 3,
          'airedEpisodeCount': 3,
          'hasFiles': true,
          'watchStatus': {
            'watched': true,
            'percentage': 1.0,
            'unwatchedEpisodeCount': 0
          }
        },
        {
          'seasonNumber': 2,
          'episodeCount': 2,
          'airedEpisodeCount': 2,
          'hasFiles': true,
          'watchStatus': {
            'watched': false,
            'percentage': 0.0,
            'unwatchedEpisodeCount': 2
          }
        },
      ],
      'nextUp': {
        'progressState': 'next',
        'episode': {
          'id': 'e-21',
          'seasonNumber': 2,
          'episodeNumber': 1,
          'title': 'Low Tide',
          'runtime': 24,
          'files': [
            {'id': 'f-e-21'}
          ],
          'progress': null
        },
      },
      'isFavorite': false,
      'cast': [
        {
          'name': 'Ines Varga',
          'character': 'Keeper',
          'profileUrl': 'https://img.example/ines.jpg'
        },
      ],
      'trailerUrl': 'https://video.example/trailer',
      'similar': [
        {
          'id': 's-9',
          'type': 'TV_SHOW',
          'title': 'Harbour Lights',
          'year': 2018,
          'artwork': art('s-9')
        },
      ],
      'watchStatus': {
        'watched': false,
        'percentage': 0.5,
        'unwatchedEpisodeCount': 2
      },
    };

Map<String, dynamic> episode(String id, {int season = 2, int number = 1}) => {
      'id': id,
      'seasonNumber': season,
      'episodeNumber': number,
      'title': 'Low Tide',
      'overview': 'The lamp fails.',
      'airDate': '2019-04-02',
      'runtime': 24,
      'thumbnailUrl': 'https://img.example/$id.jpg',
      'hasFile': true,
      'progress': {
        'positionSeconds': 60,
        'durationSeconds': 1440,
        'percentage': 4.0,
        'watched': false,
        'lastWatchedAt': null
      },
      'files': [file('f-$id')],
      'show': {
        'id': 's-1',
        'title': 'Lantern Street s-1',
        'artwork': art('s-1')
      },
    };

Map<String, dynamic> collection(String id, {String type = 'manual'}) => {
      'id': id,
      'name': 'Invented Shelf $id',
      'description': 'Picked by hand.',
      'type': type,
      'visibility': 'private',
      'itemCount': 23,
      'posterPaths': ['https://img.example/$id-1.jpg'],
    };

/// A listing-shaped map, as the listing documents select it.
Map<String, dynamic> listing(String id,
        {String type = 'MOVIE',
        bool watched = false,
        int? unwatched,
        int? newEpisodes,
        int? latestSeason,
        int? latestEpisode}) =>
    {
      'id': id,
      'type': type,
      'title': 'Invented Listing $id',
      'year': 2023,
      'artwork': art('l-$id'),
      'addedAt': '2024-05-01T00:00:00Z',
      if (newEpisodes != null) 'newEpisodeCount': newEpisodes,
      if (latestSeason != null) 'latestSeasonNumber': latestSeason,
      if (latestEpisode != null) 'latestEpisodeNumber': latestEpisode,
      'watchStatus': {
        'watched': watched,
        'percentage': 0.0,
        if (unwatched != null) 'unwatchedEpisodeCount': unwatched,
      },
    };

Map<String, dynamic> calendarEntry(String id,
        {String kind = 'episode', required String airDate}) =>
    {
      'id': id,
      'kind': kind,
      'airDate': airDate,
      'title': 'Invented Entry $id',
      'seasonNumber': kind == 'episode' ? 2 : null,
      'episodeNumber': kind == 'episode' ? 5 : null,
      'mediaItemId': 'item-$id',
      'mediaItemTitle': 'Lantern Street',
      'artwork': art('c-$id'),
      'files': [
        {'id': 'cf-1', 'directPlaySupported': false},
        {'id': 'cf-2', 'directPlaySupported': true},
      ],
    };

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

({MydiaSource source, FakeMydiaTransport t}) build(
    {void Function()? onDispose}) {
  final t = FakeMydiaTransport();
  final movies = [for (var i = 1; i <= 5; i++) movie('m-$i')];
  t.handlers['MoviesFiltered'] = (v) {
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
  t.handlers['TvShowsFiltered'] = (_) => {
        'tvShows': {
          'edges': [
            {'node': show('s-1')}
          ],
          'pageInfo': {'hasNextPage': false, 'endCursor': null},
          'totalCount': 1,
        }
      };
  t.handlers['MovieDetail'] = (v) => {'movie': movie(v['id'] as String)};
  t.handlers['TvShowDetail'] = (v) => {'tvShow': show(v['id'] as String)};
  t.handlers['EpisodeDetail'] = (v) => {'episode': episode(v['id'] as String)};
  t.handlers['SeasonEpisodes'] = (v) => {
        'seasonEpisodes': [
          episode('e-21', number: 1),
          episode('e-22', number: 2)
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
  t.handlers['RecentlyAddedFull'] = (_) => {
        'recentlyAdded': [
          recentlyAdded('m-4', addedAt: '2024-05-03T00:00:00Z'),
          recentlyAdded('s-1',
              type: 'TV_SHOW', addedAt: '2024-05-02T00:00:00Z'),
          recentlyAdded('m-1', addedAt: '2024-05-01T00:00:00Z'),
        ],
      };
  t.handlers['HomeRows'] = (_) => {
        'recentlyAdded': [listing('m-4')],
        'favorites': [listing('s-1', type: 'TV_SHOW')],
      };
  t.handlers['Collections'] = (_) => {
        'collections': [collection('c1'), collection('c2', type: 'smart')],
      };
  t.handlers['Calendar'] = (_) => {'calendar': <Object>[]};
  t.handlers['UnwatchedListing'] = (_) => {'unwatched': <Object>[]};
  t.handlers['FavoritesListing'] = (_) => {'favorites': <Object>[]};
  t.handlers['MovieMediaInfo'] = (v) => {
        'movie': {
          'id': v['id'],
          'files': [
            {'id': 'f1'}
          ]
        }
      };
  t.handlers['EpisodeMediaInfo'] = (v) => {
        'episode': {
          'id': v['id'],
          'files': [
            {'id': 'f1'}
          ]
        }
      };
  t.handlers['DevicesList'] = (_) => {'devices': <Object>[]};
  t.handlers['RegisterDeviceNode'] = (v) => {
        'registerDeviceNode': {'id': 'd1', 'nodeId': v['nodeId']}
      };
  t.handlers['RevokeDevice'] = (_) => {
        'revokeDevice': {'success': true}
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
  final client = MydiaClient(
    transport: t,
    load: () async =>
        const MydiaCredentials(instanceId: 'inst-2', accessToken: 'access'),
    save: (_) async {},
    onUnauthorized: () {},
  );
  return (
    source: MydiaSource(
        source: guest,
        client: client,
        proxy: () => throw StateError('no proxy in this test'),
        onDispose: onDispose),
    t: t
  );
}
