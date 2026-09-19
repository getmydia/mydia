import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:player/core/player/scrub_thumbnails.dart';
import 'package:player/core/player/thumbnail_service.dart';

/// What `sprite_generator.ex`'s `generate_vtt/6` writes: the sheet named by
/// checksum, hour-padded timestamps, a blank line between cues, and the first
/// cue starting past zero because the generator skips the first 2%.
const _serverVtt = '''
WEBVTT

00:02:24.000 --> 00:03:52.000
3f9a1c.jpg#xywh=0,0,160,90

00:03:52.000 --> 00:05:20.000
3f9a1c.jpg#xywh=160,0,160,90

01:10:00.000 --> 01:11:28.000
3f9a1c.jpg#xywh=0,90,160,90
''';

ThumbnailService _service(MockClientHandler handler) => ThumbnailService(
      serverUrl: 'https://media.example',
      authToken: 'tok',
      client: MockClient(handler),
    );

void main() {
  group('ThumbnailService.parseVtt', () {
    test('reads the server format', () {
      final cues = ThumbnailService.parseVtt(_serverVtt);

      expect(cues, hasLength(3));
      expect(cues[0].startTime, 144.0);
      expect(cues[0].endTime, 232.0);
      expect(cues[1].x, 160);
      expect(cues[2].startTime, 4200.0);
      expect(cues[2].y, 90);
      expect(cues[2].width, 160);
      expect(cues[2].height, 90);
    });
  });

  group('ThumbnailService', () {
    test('asks for the sheet at the endpoint the server serves', () {
      final service = ThumbnailService(
          serverUrl: 'https://media.example', authToken: 'tok');

      expect(
        service.spriteUrl('file-1'),
        'https://media.example/api/v1/media/file-1/thumbnails.jpg',
      );
      expect(service.imageHeaders, {'Authorization': 'Bearer tok'});
    });

    test('fetches the VTT with the access token, once', () async {
      final requests = <http.Request>[];
      final service = _service((request) async {
        requests.add(request);
        return http.Response(_serverVtt, 200);
      });

      final first = await service.fetchThumbnails('file-1');
      final second = await service.fetchThumbnails('file-1');

      expect(first, hasLength(3));
      expect(identical(first, second), isTrue);
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/api/v1/media/file-1/thumbnails.vtt');
      expect(requests.single.headers['Authorization'], 'Bearer tok');
    });

    test('remembers that a file has no thumbnails', () async {
      var requests = 0;
      final service = _service((_) async {
        requests++;
        return http.Response('{"error":"none"}', 404);
      });

      expect(await service.fetchThumbnails('file-1'), isEmpty);
      expect(await service.fetchThumbnails('file-1'), isEmpty);
      expect(requests, 1);
    });

    test('does not remember a server error', () async {
      var requests = 0;
      final service = _service((_) async {
        requests++;
        return http.Response('boom', 500);
      });

      expect(await service.fetchThumbnails('file-1'), isEmpty);
      expect(await service.fetchThumbnails('file-1'), isEmpty);
      expect(requests, 2);
    });

    test('a network failure yields no thumbnails', () async {
      final service =
          _service((_) async => throw http.ClientException('offline'));

      expect(await service.fetchThumbnails('file-1'), isEmpty);
    });

    group('cueFor', () {
      final cues = ThumbnailService.parseVtt(_serverVtt);
      final service =
          ThumbnailService(serverUrl: 'https://media.example', authToken: 't');

      test('the cue covering the time', () {
        expect(service.cueFor(cues, 200)!.startTime, 144.0);
      });

      test('the nearest cue inside the leading gap', () {
        expect(service.cueFor(cues, 10)!.startTime, 144.0);
      });

      test('the nearest cue past the last one', () {
        expect(service.cueFor(cues, 9000)!.startTime, 4200.0);
      });

      test('the nearest cue in a gap between cues', () {
        // 3000 s is 2680 s past cue 1's end and 1200 s before cue 2's start.
        expect(service.cueFor(cues, 3000)!.startTime, 4200.0);
      });

      test('null with no cues', () {
        expect(service.cueFor(const [], 10), isNull);
      });
    });
  });

  group('ScrubThumbnails', () {
    test('fetches once, on the first ensureLoaded, and notifies', () async {
      var requests = 0;
      final thumbnails = ScrubThumbnails(
        service: _service((_) async {
          requests++;
          return http.Response(_serverVtt, 200);
        }),
        fileId: 'file-1',
      );
      var notified = 0;
      thumbnails.addListener(() => notified++);

      expect(thumbnails.cueAt(const Duration(minutes: 3)), isNull);
      expect(requests, 0);

      thumbnails.ensureLoaded();
      thumbnails.ensureLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(requests, 1);
      expect(notified, 1);
      expect(thumbnails.cueAt(const Duration(minutes: 3))!.x, 0);
      expect(
        thumbnails.spriteUrl,
        'https://media.example/api/v1/media/file-1/thumbnails.jpg',
      );
      thumbnails.dispose();
    });

    test('a file with no sprites stays silent', () async {
      final thumbnails = ScrubThumbnails(
        service: _service((_) async => http.Response('', 404)),
        fileId: 'file-1',
      );
      var notified = 0;
      thumbnails.addListener(() => notified++);

      thumbnails.ensureLoaded();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(notified, 0);
      expect(thumbnails.cueAt(const Duration(minutes: 3)), isNull);
      thumbnails.dispose();
    });
  });
}
