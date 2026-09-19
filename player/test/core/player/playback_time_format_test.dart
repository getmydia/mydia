import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/playback_time_format.dart';

void main() {
  test('minutes and seconds under an hour', () {
    expect(formatPlaybackTime(const Duration(minutes: 2, seconds: 5)), '02:05');
  });

  test('hours once past the hour', () {
    expect(
      formatPlaybackTime(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '01:02:03',
    );
  });

  test('zero', () {
    expect(formatPlaybackTime(Duration.zero), '00:00');
  });
}
