import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/router/app_router.dart';

void main() {
  group('PlayerRouteParams.fromUri', () {
    test('reads back every field a route can carry', () {
      final uri = Uri.parse(
        '/player/episode/ep-1?fileId=file-1&title=Half+Loop'
        '&showId=show-1&seasonNumber=2&resume=120'
        '&audioTrack=audio-eng&subtitleTrack=sub-fre&autoplay=false',
      );

      final params = PlayerRouteParams.fromUri(uri);

      expect(params.fileId, 'file-1');
      expect(params.title, 'Half Loop');
      expect(params.showId, 'show-1');
      expect(params.seasonNumber, 2);
      expect(params.resumeSeconds, 120);
      expect(params.audioTrack, 'audio-eng');
      expect(params.subtitleTrack, 'sub-fre');
      expect(params.autoplay, isFalse);
    });

    test('defaults to autoplay true and every other field null when absent',
        () {
      final params = PlayerRouteParams.fromUri(Uri.parse('/player/movie/m1'));

      expect(params.fileId, isNull);
      expect(params.title, isNull);
      expect(params.showId, isNull);
      expect(params.seasonNumber, isNull);
      expect(params.resumeSeconds, isNull);
      expect(params.audioTrack, isNull);
      expect(params.subtitleTrack, isNull);
      expect(params.autoplay, isTrue);
    });
  });
}
