import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An invented Plex server with one movie library of five titles and one
/// show with one season of two episodes.
class FakePlexServer {
  static const machineId = 'aa11';
  static final base = Uri.parse('https://10-0-0-5.aa11.plex.direct:32400');
  static const token = 'server-token-1';

  final requests = <http.Request>[];

  /// Set to make every request after the identity probe answer this code.
  int? status;

  /// Set to make every request after the identity probe fail at the
  /// transport level, as a dropped connection does.
  bool throwTransport = false;

  /// Set to make the transcode decision refuse the conversion.
  bool refuseTranscode = false;

  /// Set to make `/hubs` also answer a repeated hub id and a hub holding
  /// more movies than a row may show.
  bool crowdedHubs = false;

  /// Set to make the show answer without an `OnDeck` entry.
  bool nothingOnDeck = false;

  /// What an episode's `Marker` list holds when asked with
  /// `includeMarkers=1`.
  List<Map<String, dynamic>> markers = [];

  static const movies = [
    ('101', 'The Lantern Keeper', 2019),
    ('102', 'Saltwater Clocks', 2021),
    ('103', 'A Quiet Orbit', 2015),
    ('104', 'Paper Harbour', 2023),
    ('105', 'Nine Copper Bells', 2012),
  ];

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (path == '/identity') {
      return _json({
        'MediaContainer': {'machineIdentifier': machineId},
      });
    }
    if (throwTransport) throw http.ClientException('connection refused');
    final forced = status;
    if (forced != null) return http.Response('', forced);
    if (request.headers['X-Plex-Token'] != token) {
      return http.Response('', 401);
    }
    final q = request.url.queryParameters;
    switch (path) {
      case '/library/sections':
        return _container({
          'Directory': [
            {
              'key': '1',
              'title': 'Films',
              'type': 'movie',
              'agent': 'tv.plex.agents.movie',
            },
            {
              'key': '2',
              'title': 'Series',
              'type': 'show',
              'agent': 'tv.plex.agents.series',
            },
            {'key': '3', 'title': 'Music', 'type': 'artist'},
          ],
        });
      case '/library/sections/1/all':
        final start = int.parse(q['X-Plex-Container-Start'] ?? '0');
        final size = int.parse(q['X-Plex-Container-Size'] ?? '50');
        final page = movies.skip(start).take(size).toList();
        return _container({
          'offset': start,
          'size': page.length,
          'totalSize': movies.length,
          'Metadata': [for (final m in page) _movie(m.$1, m.$2, m.$3)],
        });
      case '/library/metadata/101':
        return _container({
          'Metadata': [
            {
              ..._movie('101', 'The Lantern Keeper', 2019),
              'summary': 'A keeper tends a light no ship needs.',
              'audienceRating': 7.4,
              'studio': 'Fernhollow Pictures',
              'Genre': [
                {'tag': 'Drama'},
              ],
              'contentRating': 'PG',
              'Role': [
                {
                  'tag': 'Ana Bergström',
                  'role': 'Kira Solt',
                  'thumb': 'https://metadata-static.plex.tv/people/a.jpg',
                },
              ],
              'Media': [
                {
                  'id': 11,
                  'duration': 5400000,
                  'bitrate': 8000,
                  'height': 1080,
                  'container': 'mkv',
                  'videoCodec': 'hevc',
                  'audioCodec': 'eac3',
                  'Part': [
                    {
                      'id': 21,
                      'key': '/library/parts/21/1700000000/file.mkv',
                      'duration': 5400000,
                      'container': 'mkv',
                      'Stream': [
                        {'id': 31, 'streamType': 1, 'codec': 'hevc'},
                        {
                          'id': 32,
                          'streamType': 2,
                          'codec': 'eac3',
                          'languageCode': 'eng',
                          'displayTitle': 'English (EAC3 5.1)',
                          'selected': true,
                        },
                        {
                          'id': 33,
                          'streamType': 3,
                          'codec': 'srt',
                          'languageCode': 'spa',
                          'displayTitle': 'Spanish (SRT External)',
                          'key': '/library/streams/33',
                        },
                        {
                          'id': 34,
                          'streamType': 3,
                          'codec': 'pgs',
                          'languageCode': 'eng',
                          'displayTitle': 'English (PGS)',
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          ],
        });
      case '/library/metadata/401':
      case '/library/metadata/402':
        return _container({
          'Metadata': [
            {
              ..._episode(int.parse(path.substring(path.length - 1))),
              if (q['includeMarkers'] == '1') 'Marker': markers,
            },
          ],
        });
      case '/library/metadata/101/similar':
        return _container({
          'Metadata': [
            _movie('102', 'Saltwater Clocks', 2021),
            _movie('103', 'A Quiet Orbit', 2015),
          ],
        });
      case '/library/metadata/201':
        return _container({
          'Metadata': [
            {
              'ratingKey': '201',
              'type': 'show',
              'title': 'Harbour Lights',
              'year': 2020,
              'thumb': '/library/metadata/201/thumb/1',
              'leafCount': 2,
              'viewedLeafCount': 1,
              'childCount': 1,
              'summary': 'Two lighthouses, one keeper.',
              if (q['includeOnDeck'] == '1' && !nothingOnDeck)
                'OnDeck': {
                  'Metadata': [_episode(2)]
                },
            },
          ],
        });
      case '/library/metadata/201/children':
        return _container({
          'offset': 0,
          'size': 1,
          'totalSize': 1,
          'Metadata': [
            {
              'ratingKey': '301',
              'type': 'season',
              'title': 'Season 1',
              'index': 1,
              'leafCount': 2,
              'viewedLeafCount': 1,
              'thumb': '/library/metadata/301/thumb/1',
            },
          ],
        });
      case '/library/metadata/301/children':
        return _container({
          'offset': 0,
          'size': 2,
          'totalSize': 2,
          'Metadata': [
            _episode(1),
            _episode(2),
          ],
        });
      case '/hubs/search':
        return _container({
          'Hub': [
            {
              'type': 'movie',
              'Metadata': [_movie('102', 'Saltwater Clocks', 2021)],
            },
            {
              'type': 'actor',
              'Metadata': [
                {'type': 'tag', 'tag': 'Ines Varga'},
              ],
            },
          ],
        });
      case '/library/recentlyAdded':
        return _container({
          'Metadata': [
            {..._movie('104', 'Paper Harbour', 2023), 'addedAt': 1700200000},
            {..._movie('102', 'Saltwater Clocks', 2021), 'addedAt': 1700100000},
          ],
        });
      case '/hubs/continueWatching/items':
        return _container({
          'size': 2,
          'Metadata': [
            resumingEpisode,
            {..._movie('103', 'A Quiet Orbit', 2015), 'viewOffset': 1800000},
          ],
        });
      case '/hubs':
        return _container({
          'Hub': [
            {
              'hubIdentifier': 'home.continue',
              'title': 'Continue Watching',
              'type': 'mixed',
              'Metadata': [resumingEpisode],
            },
            {
              'hubIdentifier': 'home.ondeck',
              'title': 'On Deck',
              'type': 'mixed',
              'Metadata': [resumingEpisode],
            },
            {
              'hubIdentifier': 'home.movies.recent',
              'title': 'Recently Added in Films',
              'type': 'movie',
              'Metadata': [
                _movie('104', 'Paper Harbour', 2023),
                _movie('105', 'Nine Copper Bells', 2012),
              ],
            },
            {
              'hubIdentifier': 'home.mixed.released',
              'title': 'Recently Released',
              'type': 'mixed',
              'Metadata': [
                _movie('101', 'The Lantern Keeper', 2019),
                showSummary,
              ],
            },
            if (crowdedHubs) ...[
              {
                'hubIdentifier': 'home.movies.recent',
                'title': 'Recently Added in Films, again',
                'type': 'movie',
                'Metadata': [_movie('101', 'The Lantern Keeper', 2019)],
              },
              {
                'hubIdentifier': 'home.movies.long',
                'title': 'A Long Shelf',
                'type': 'movie',
                'Metadata': [
                  for (var i = 0; i < 25; i++)
                    _movie('${700 + i}', 'Shelf Film $i', 2000 + i),
                ],
              },
            ],
            {
              'hubIdentifier': 'home.music.recent',
              'title': 'Recently Added in Music',
              'type': 'album',
              'Metadata': [
                {
                  'ratingKey': '901',
                  'type': 'album',
                  'title': 'Lowtide Hymns',
                  'librarySectionID': 3,
                },
              ],
            },
            {
              'hubIdentifier': 'home.television.recent',
              'title': 'Recently Added in Series',
              'type': 'episode',
              'Metadata': <Object>[],
            },
          ],
        });
      case '/actions/removeFromContinueWatching':
        return http.Response('', 200);
      case '/:/scrobble':
      case '/:/unscrobble':
      case '/:/timeline':
        return http.Response('', 200);
      case '/video/:/transcode/universal/decision':
        return refuseTranscode
            ? _container({
                'generalDecisionCode': 2000,
                'generalDecisionText':
                    'The video codec is not supported by this server.',
              })
            : _container({
                'generalDecisionCode': 1001,
                'generalDecisionText':
                    'Direct play not available; Conversion OK',
              });
      case '/video/:/transcode/universal/stop':
        return http.Response('', 200);
      case '/library/parts/21':
        return http.Response('', 200);
      case '/library/streams/33':
        return http.Response('1\n00:00:01,000 --> 00:00:02,000\nHola\n', 200);
    }
    return http.Response('', 404);
  });

  static Map<String, dynamic> _movie(String id, String title, int year) => {
        'ratingKey': id,
        'type': 'movie',
        'title': title,
        'year': year,
        'thumb': '/library/metadata/$id/thumb/1700',
        'art': '/library/metadata/$id/art/1700',
        'duration': 5400000,
        'librarySectionID': 1,
      };

  static Map<String, dynamic> _episode(int n) => {
        'ratingKey': '40$n',
        'type': 'episode',
        'title': n == 1 ? 'First Light' : 'Fog Bank',
        'index': n,
        'parentIndex': 1,
        'grandparentTitle': 'Harbour Lights',
        'grandparentRatingKey': '201',
        'parentRatingKey': '301',
        'summary': 'An invented episode.',
        'originallyAvailableAt': '2024-01-0$n',
        if (n == 1) 'viewCount': 1,
        if (n == 2) 'viewOffset': 600000,
        'duration': 1800000,
        'thumb': '/library/metadata/40$n/thumb/1',
        'Media': [
          {
            'id': 60 + n,
            'Part': [
              {'id': 500 + n},
            ],
          },
        ],
      };

  /// Episode 402, mid-way, as Continue Watching and the hubs return it.
  static Map<String, dynamic> get resumingEpisode => {
        'ratingKey': '402',
        'type': 'episode',
        'title': 'Fog Bank',
        'index': 2,
        'parentIndex': 1,
        'grandparentTitle': 'Harbour Lights',
        'grandparentThumb': '/library/metadata/201/thumb/1',
        'thumb': '/library/metadata/402/thumb/1',
        'viewOffset': 600000,
        'duration': 1800000,
        'librarySectionID': 2,
      };

  static Map<String, dynamic> get showSummary => {
        'ratingKey': '201',
        'type': 'show',
        'title': 'Harbour Lights',
        'year': 2020,
        'thumb': '/library/metadata/201/thumb/1',
        'leafCount': 2,
        'viewedLeafCount': 1,
        'librarySectionID': 2,
      };

  static http.Response _container(Map<String, dynamic> body) =>
      _json({'MediaContainer': body});

  static http.Response _json(Object body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
}
