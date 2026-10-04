import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An invented Jellyfin 10.10 server: five films, one show with one season
/// of two episodes, and a music library the player must skip.
class FakeJellyfinServer {
  static final base = Uri.parse('https://media.example.test');
  static const serverId = 'f0e1d2c3b4a5968778695a4b3c2d1e0f';
  static const userId = '0123456789abcdef0123456789abcdef';
  static const token = 'jf-token-1';
  static const username = 'marlow';
  static const password = 'correct horse';
  static const ticks = 10000000;

  final requests = <http.Request>[];
  int? status;
  String version = '10.10.3';
  String productName = 'Jellyfin Server';
  String? localAddress = 'http://192.168.1.30:8096';
  bool quickConnectEnabled = true;
  bool quickConnectApproved = false;
  bool quickConnectExpired = false;
  bool directPlay = true;
  bool directStream = true;
  bool transcoding = true;
  String? playbackErrorCode;

  /// What `/UserItems/Resume` and `/Shows/NextUp` answer, in that order.
  List<Map<String, dynamic>> resumeItems = [];
  List<Map<String, dynamic>> nextUpItems = [];

  /// Paths that answer 500, to fail one request of several.
  final failing = <String>{};

  /// Favorite toggles as (method, item id), in arrival order.
  final favoriteCalls = <(String, String)>[];

  /// Request bodies by path, decoded, in arrival order.
  final bodies = <(String, Map<String, dynamic>)>[];

  static Map<String, dynamic> movie(int n,
          {bool played = false, int positionSeconds = 0}) =>
      {
        'Id': 'm$n',
        'Name': 'Lantern Bay $n',
        'Type': 'Movie',
        'ProductionYear': 2010 + n,
        'RunTimeTicks': 5400 * ticks,
        'ImageTags': {'Primary': 'p$n'},
        'BackdropImageTags': ['b$n'],
        'UserData': {
          'Played': played,
          'PlaybackPositionTicks': positionSeconds * ticks,
        },
        'Overview': 'Invented film number $n.',
        'Genres': ['Drama'],
        'People': [
          {'Name': 'Ilse Corran'}
        ],
        'Studios': [
          {'Name': 'Northwind'}
        ],
        'CommunityRating': 7.5,
        'MediaSources': [
          {
            'Id': 'm$n',
            'Container': 'mkv',
            'Bitrate': 8000000,
            'RunTimeTicks': 5400 * ticks,
            'MediaStreams': [
              {'Index': 0, 'Type': 'Video', 'Codec': 'hevc', 'Height': 1080},
              {
                'Index': 1,
                'Type': 'Audio',
                'Codec': 'eac3',
                'Language': 'eng',
                'DisplayTitle': 'English EAC3 5.1',
                'IsDefault': true,
              },
              {
                'Index': 2,
                'Type': 'Subtitle',
                'Codec': 'subrip',
                'Language': 'eng',
                'DisplayTitle': 'English',
                'IsExternal': false,
              },
              {
                'Index': 3,
                'Type': 'Subtitle',
                'Codec': 'subrip',
                'Language': 'spa',
                'DisplayTitle': 'Spanish',
                'IsExternal': true,
              },
            ],
          },
        ],
      };

  static Map<String, dynamic> episode(int n) => {
        'Id': 'e$n',
        'Name': 'The Quiet Tide $n',
        'Type': 'Episode',
        'SeriesId': 'show1',
        'SeriesName': 'Saltmarsh',
        'SeriesPrimaryImageTag': 'sp',
        'IndexNumber': n,
        'ParentIndexNumber': 1,
        'RunTimeTicks': 2700 * ticks,
        'ImageTags': {'Primary': 'ep$n'},
        'UserData': {'Played': n == 1, 'PlaybackPositionTicks': 0},
      };

  static const show = {
    'Id': 'show1',
    'Name': 'Saltmarsh',
    'Type': 'Series',
    'ProductionYear': 2019,
    'ChildCount': 1,
    'ImageTags': {'Primary': 'sp'},
    'UserData': {'Played': false},
  };

  static const season = {
    'Id': 'season1',
    'Name': 'Season 1',
    'Type': 'Season',
    'IndexNumber': 1,
    'ChildCount': 2,
    'ImageTags': {'Primary': 's1p'},
    'UserData': {'Played': false},
  };

  static Map<String, dynamic> get session => {
        'AccessToken': token,
        'User': {
          'Id': userId,
          'Name': username,
          'Policy': {'IsAdministrator': true},
        },
      };

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    final forced = status;
    if (forced != null) return http.Response('', forced);
    final path = request.url.path;
    final q = request.url.queryParameters;
    final body = request.body.isEmpty
        ? const <String, dynamic>{}
        : (jsonDecode(request.body) as Map).cast<String, dynamic>();
    if (request.body.isNotEmpty) bodies.add((path, body));

    // Unauthenticated endpoints.
    switch ((request.method, path)) {
      case ('GET', '/System/Info/Public'):
        return _json({
          'Id': serverId,
          'ServerName': 'Harbor',
          'Version': version,
          'ProductName': productName,
          if (localAddress != null) 'LocalAddress': localAddress,
        });
      case ('GET', '/QuickConnect/Enabled'):
        return _json(quickConnectEnabled);
      case ('POST', '/QuickConnect/Initiate'):
        return _json({'Code': '482913', 'Secret': 'qc-secret'});
      case ('GET', '/QuickConnect/Connect'):
        if (quickConnectExpired) return http.Response('', 404);
        return _json({'Authenticated': quickConnectApproved});
      case ('POST', '/Users/AuthenticateWithQuickConnect'):
        return quickConnectApproved && body['Secret'] == 'qc-secret'
            ? _json(session)
            : http.Response('', 401);
      case ('POST', '/Users/AuthenticateByName'):
        return body['Username'] == username && body['Pw'] == password
            ? _json(session)
            : http.Response('', 401);
    }

    if (!(request.headers['Authorization'] ?? '').contains('Token="$token"')) {
      return http.Response('', 401);
    }

    if (failing.contains(path)) return http.Response('', 500);
    if (request.method == 'GET' && path == '/Items/Latest') {
      // A bare array, unlike every other list endpoint.
      return _json([
        // A grouped series: old DateCreated, newest episode arrival.
        {
          ...show,
          'DateCreated': '2020-01-01T00:00:00.0000000Z',
          'DateLastMediaAdded': '2024-05-04T10:00:00.0000000Z',
        },
        {...movie(3), 'DateCreated': '2024-05-03T10:00:00.0000000Z'},
        {...movie(1), 'DateCreated': '2024-05-01T10:00:00.0000000Z'},
      ]);
    }
    if (request.method == 'GET' && path == '/UserItems/Resume') {
      return _json(
          {'Items': resumeItems, 'TotalRecordCount': resumeItems.length});
    }
    if (request.method == 'GET' && path == '/Shows/NextUp') {
      final series = q['seriesId'];
      final items = [
        for (final m in nextUpItems)
          if (series == null || m['SeriesId'] == series) m,
      ];
      return _json({'Items': items, 'TotalRecordCount': items.length});
    }
    if (request.method == 'GET' &&
        RegExp(r'^/Items/[^/]+/Similar$').hasMatch(path)) {
      return _json({
        'Items': [movie(4), movie(5)],
        'TotalRecordCount': 2,
      });
    }
    final favorite = RegExp(r'^/UserFavoriteItems/([^/]+)$').firstMatch(path);
    if (favorite != null &&
        (request.method == 'POST' || request.method == 'DELETE')) {
      favoriteCalls.add((request.method, favorite.group(1)!));
      return _json({'IsFavorite': request.method == 'POST'});
    }
    if (request.method == 'POST' &&
        RegExp(r'^/UserItems/[^/]+/UserData$').hasMatch(path)) {
      return _json({'PlaybackPositionTicks': body['PlaybackPositionTicks']});
    }

    if (request.method == 'GET' && path == '/UserViews') {
      return _json({
        'Items': [
          {'Id': 'lib-movies', 'Name': 'Films', 'CollectionType': 'movies'},
          {'Id': 'lib-shows', 'Name': 'Series', 'CollectionType': 'tvshows'},
          {'Id': 'lib-music', 'Name': 'Tunes', 'CollectionType': 'music'},
        ],
        'TotalRecordCount': 3,
      });
    }
    if (request.method == 'GET' && path == '/Items') {
      List<Map<String, dynamic>> all;
      if (q['searchTerm'] case final term?) {
        all = [
          for (var n = 1; n <= 5; n++) movie(n),
        ].where((m) => (m['Name'] as String).contains(term)).toList();
      } else {
        all = switch (q['ParentId']) {
          'lib-movies' => [for (var n = 1; n <= 5; n++) movie(n)],
          'lib-shows' => [show],
          'season1' => [episode(1), episode(2)],
          _ => [],
        };
      }
      final start = int.tryParse(q['StartIndex'] ?? '') ?? 0;
      final limit = int.tryParse(q['Limit'] ?? '') ?? all.length;
      return _json({
        'Items': all.skip(start).take(limit).toList(),
        'TotalRecordCount': all.length,
      });
    }
    if (request.method == 'GET' && path == '/Shows/show1/Seasons') {
      return _json({
        'Items': [season],
        'TotalRecordCount': 1,
      });
    }
    final item = RegExp(r'^/Items/(m\d)$').firstMatch(path);
    if (request.method == 'GET' && item != null) {
      final n = int.parse(item.group(1)!.substring(1));
      return _json(movie(n, played: false, positionSeconds: 300));
    }
    final info = RegExp(r'^/Items/(m\d)/PlaybackInfo$').firstMatch(path);
    if (request.method == 'POST' && info != null) {
      final id = info.group(1)!;
      if (playbackErrorCode case final code?) {
        return _json({'ErrorCode': code, 'MediaSources': <Object?>[]});
      }
      return _json({
        'PlaySessionId': 'ps1',
        'MediaSources': [
          {
            ...(movie(int.parse(id.substring(1)))['MediaSources'] as List).first
                as Map<String, dynamic>,
            'SupportsDirectPlay': directPlay,
            'SupportsDirectStream': directStream,
            'SupportsTranscoding': transcoding,
          },
        ],
      });
    }
    if (path.startsWith('/UserPlayedItems/') ||
        path.startsWith('/Sessions/Playing') ||
        path == '/Videos/ActiveEncodings') {
      return http.Response('', 204);
    }
    if (path == '/Videos/m2/m2/Subtitles/3/Stream.srt') {
      return http.Response('1\n00:00:01,000 --> 00:00:02,000\nHola\n', 200);
    }
    return http.Response('', 404);
  });

  static http.Response _json(Object? body, [int status = 200]) => http.Response(
        jsonEncode(body),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
}
