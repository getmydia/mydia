import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/media_session/playing_source.dart';
import 'package:player/core/sources/source.dart';

void main() {
  const a = SourceId('acct:owner:a');
  const b = SourceId('acct:owner:b');

  test('release clears only for the owner that still holds the claim', () {
    final playing = PlayingSource();
    final first = Object();
    final second = Object();

    playing.claim(first, a);
    playing.claim(second, b);
    playing.release(first);
    expect(playing.current, b);

    playing.release(second);
    expect(playing.current, isNull);
  });
}
