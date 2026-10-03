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
              'Role': [
                {'tag': 'Ines Varga'},
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
            {
              'ratingKey': '401',
              'type': 'episode',
              'title': 'First Light',
              'index': 1,
              'parentIndex': 1,
              'grandparentTitle': 'Harbour Lights',
              'viewCount': 1,
              'duration': 1800000,
              'thumb': '/library/metadata/401/thumb/1',
            },
            {
              'ratingKey': '402',
              'type': 'episode',
              'title': 'Fog Bank',
              'index': 2,
              'parentIndex': 1,
              'grandparentTitle': 'Harbour Lights',
              'viewOffset': 600000,
              'duration': 1800000,
              'thumb': '/library/metadata/402/thumb/1',
            },
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
      case '/:/scrobble':
      case '/:/unscrobble':
      case '/:/timeline':
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
      };

  static http.Response _container(Map<String, dynamic> body) =>
      _json({'MediaContainer': body});

  static http.Response _json(Object body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
}
