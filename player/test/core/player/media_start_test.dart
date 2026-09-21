import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/media_start.dart';

void main() {
  const headers = {'Authorization': 'Bearer tok'};
  const url = 'https://mydia.test/stream.m3u8';

  test('native carries a resume in the open and never seeks after it', () {
    final opening = mediaStartingAt(url,
        httpHeaders: headers,
        position: const Duration(seconds: 1200),
        isWeb: false);

    expect(opening.media.start, const Duration(seconds: 1200));
    expect(opening.media.httpHeaders, headers);
    expect(opening.seekAfterOpen, isFalse);
  });

  test('web seeks after the open and leaves start unset', () {
    final opening = mediaStartingAt(url,
        httpHeaders: headers,
        position: const Duration(seconds: 1200),
        isWeb: true);

    expect(opening.media.start, isNull);
    expect(opening.seekAfterOpen, isTrue);
  });

  for (final isWeb in [false, true]) {
    test('starting from zero neither sets start nor seeks (isWeb: $isWeb)', () {
      final opening = mediaStartingAt(url,
          httpHeaders: headers, position: Duration.zero, isWeb: isWeb);

      expect(opening.media.start, isNull);
      expect(opening.seekAfterOpen, isFalse);
    });
  }
}
