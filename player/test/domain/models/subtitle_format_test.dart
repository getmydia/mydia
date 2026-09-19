import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/subtitle_format.dart';

void main() {
  test('recognizes the server\'s normalized bitmap formats', () {
    for (final format in ['pgs', 'vobsub', 'dvb_subtitle', 'xsub']) {
      expect(isImageSubtitleFormat(format), isTrue, reason: format);
    }
  });

  test('recognizes ffprobe\'s and mpv\'s codec names, in any case', () {
    for (final codec in [
      'hdmv_pgs_subtitle',
      'dvd_subtitle',
      'HDMV_PGS_SUBTITLE',
    ]) {
      expect(isImageSubtitleFormat(codec), isTrue, reason: codec);
    }
  });

  test('treats text formats and nothing as text', () {
    for (final format in [
      'srt',
      'subrip',
      'ass',
      'vtt',
      'webvtt',
      'mov_text',
      null,
    ]) {
      expect(isImageSubtitleFormat(format), isFalse, reason: '$format');
    }
  });
}
