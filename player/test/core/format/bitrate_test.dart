import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/format/bitrate.dart';

void main() {
  test('below a megabit reads in kilobits', () {
    expect(formatBitrate(0), '0 kb/s');
    expect(formatBitrate(640), '640 kb/s');
    expect(formatBitrate(999), '999 kb/s');
  });

  test('a megabit and up reads in megabits, to one decimal', () {
    expect(formatBitrate(1000), '1.0 Mb/s');
    expect(formatBitrate(6200), '6.2 Mb/s');
    expect(formatBitrate(14200), '14.2 Mb/s');
  });

  // 6249 rounds down to 6.2 and 6250 rounds up to 6.3: the boundary is
  // worth pinning, because a naive truncation gets both wrong.
  test('rounds to the nearest tenth', () {
    expect(formatBitrate(6249), '6.2 Mb/s');
    expect(formatBitrate(6250), '6.3 Mb/s');
    expect(formatBitrate(9950), '10.0 Mb/s');
  });
}
