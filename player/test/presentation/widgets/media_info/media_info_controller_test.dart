import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/media_info/media_info_controller.dart';

void main() {
  test('maps external subtitles from the query payload', () {
    final file = mediaFileInfoFromJson({
      'id': 7,
      'fileName': 'Movie.mkv',
      'externalSubtitles': [
        {
          'trackId': 'ext-1',
          'language': 'por',
          'title': 'Portugues (Brasil)',
          'format': 'srt',
          'embedded': false,
        },
      ],
    });

    expect(file.externalSubtitles, hasLength(1));

    final track = file.externalSubtitles.single;
    expect(track.id, 'ext-1');
    expect(track.language, 'por');
    expect(track.title, 'Portugues (Brasil)');
    expect(track.format, 'srt');
    expect(track.embedded, isFalse);
  });

  test('defaults external subtitles to empty when the field is absent', () {
    // The legacy fallback query does not select externalSubtitles, so an older
    // server yields a payload without the key at all.
    final file = mediaFileInfoFromJson({'id': 7, 'fileName': 'Movie.mkv'});

    expect(file.externalSubtitles, isEmpty);
  });

  test('still maps the scalar file fields', () {
    final file = mediaFileInfoFromJson({
      'id': 7,
      'fileName': 'Movie.mkv',
      'container': 'mkv',
      'size': 8400000,
      'duration': 5400.0,
      'resolution': '1080p',
      'codec': 'h264',
    });

    expect(file.id, '7');
    expect(file.container, 'mkv');
    expect(file.sizeBytes, 8400000);
    expect(file.durationSeconds, 5400.0);
    expect(file.resolution, '1080p');
  });
}
