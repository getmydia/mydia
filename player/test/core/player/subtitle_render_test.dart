import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/subtitle_render.dart';

void main() {
  test('mpv draws the bitmap codecs mpv reports', () {
    for (final codec in [
      'hdmv_pgs_subtitle',
      'dvd_subtitle',
      'dvb_subtitle',
      'xsub',
    ]) {
      expect(mpvDrawsSubtitle(codec), isTrue, reason: codec);
    }
  });

  test('text stays with the Flutter overlay', () {
    for (final codec in ['subrip', 'ass', 'webvtt', 'mov_text', null]) {
      expect(mpvDrawsSubtitle(codec), isFalse, reason: '$codec');
    }
  });
}
