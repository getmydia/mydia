import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An invented Stash server with five scenes. Answers by GraphQL operation
/// name.
class FakeStashServer {
  static final base = Uri.parse('http://192.168.1.20:9999');
  static const apiKey = 'stash-key-1';

  final requests = <http.Request>[];
  final operations = <(String, Map<String, dynamic>)>[];
  int? status;

  /// When set, every GraphQL answer is this error message instead.
  String? graphqlError;

  static Map<String, dynamic> scene(int n,
          {int plays = 0, double resume = 0}) =>
      {
        'id': '$n',
        'title': n == 3 ? '' : 'Tidepool Study $n',
        'details': 'Invented scene number $n.',
        'date': '2022-0$n-1$n',
        'rating100': 80,
        'play_count': plays,
        'resume_time': resume,
        'files': [
          {
            'id': '9$n',
            'path': '/media/tidepool_$n.mp4',
            'basename': 'tidepool_$n.mp4',
            'duration': 1200.5,
            'video_codec': 'h264',
            'audio_codec': 'aac',
            'width': 1920,
            'height': 1080,
            'bit_rate': 6000000,
            'format': 'mp4',
          },
        ],
        'paths': {
          'screenshot':
              'http://192.168.1.20:9999/scene/$n/screenshot?t=1700&apikey=$apiKey',
          'caption': 'http://192.168.1.20:9999/scene/$n/caption',
        },
        'captions': [
          {'language_code': 'en', 'caption_type': 'srt'},
        ],
        'studio': {'name': 'Kelpline'},
        'performers': [
          {'name': 'Oona Marsh'}
        ],
        'tags': [
          {'name': 'Coastal'}
        ],
      };

  late final MockClient client = MockClient((request) async {
    requests.add(request);
    final forced = status;
    if (forced != null) return http.Response('', forced);
    if (request.headers['ApiKey'] != apiKey) return http.Response('', 401);
    if (request.url.path.startsWith('/scene/') &&
        request.url.path.endsWith('/caption')) {
      return http.Response('1\n00:00:01,000 --> 00:00:02,000\nHello\n', 200);
    }
    if (request.url.path != '/graphql') return http.Response('', 404);
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final document = body['query'] as String;
    final variables =
        (body['variables'] as Map?)?.cast<String, dynamic>() ?? const {};
    final name =
        RegExp(r'(query|mutation)\s+(\w+)').firstMatch(document)?.group(2) ??
            '';
    operations.add((name, variables));
    final error = graphqlError;
    if (error != null) {
      return _json({
        'errors': [
          {'message': error}
        ]
      });
    }
    switch (name) {
      case 'SystemStatus':
        return _json({
          'data': {
            'systemStatus': {'status': 'OK'}
          }
        });
      case 'FindScenes':
        final filter = (variables['filter'] as Map?) ?? const {};
        final page = filter['page'] as int? ?? 1;
        final perPage = filter['per_page'] as int? ?? 25;
        final q = filter['q'] as String?;
        var all = [for (var n = 1; n <= 5; n++) scene(n)];
        if (q != null) {
          all = all.where((s) => '${s['title']}'.contains(q)).toList();
        }
        final slice = all.skip((page - 1) * perPage).take(perPage).toList();
        return _json({
          'data': {
            'findScenes': {'count': all.length, 'scenes': slice}
          }
        });
      case 'FindScene':
        final id = int.parse(variables['id'] as String);
        return _json({
          'data': {'findScene': scene(id, plays: 1, resume: 300)}
        });
      case 'SceneStreams':
        final id = variables['id'];
        return _json({
          'data': {
            'sceneStreams': [
              {
                'url':
                    'http://192.168.1.20:9999/scene/$id/stream?apikey=$apiKey',
                'mime_type': 'video/mp4',
                'label': 'Direct stream'
              },
              {
                'url':
                    'http://192.168.1.20:9999/scene/$id/stream.m3u8?resolution=STANDARD_HD&apikey=$apiKey',
                'mime_type': 'application/vnd.apple.mpegurl',
                'label': 'HLS'
              },
            ]
          }
        });
      case 'SaveActivity':
        return _json({
          'data': {'sceneSaveActivity': true}
        });
      case 'AddPlay':
        return _json({
          'data': {
            'sceneAddPlay': {'count': 1}
          }
        });
      case 'ResetPlayCount':
        return _json({
          'data': {'sceneResetPlayCount': 0}
        });
    }
    return _json({
      'errors': [
        {'message': 'Cannot query field "$name"'}
      ]
    });
  });

  static http.Response _json(Object body) => http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
}
