import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/player/session/mydia_playback_session.dart';
import 'package:player/presentation/screens/player/session/playback_session_types.dart';

void main() {
  test('Mydia keeps the player route it always used', () {
    final session = MydiaPlaybackSession(
      client: () => null,
      awaitClient: () => throw UnimplementedError(),
      target: () => const PlaybackTarget(
          mediaType: 'episode', mediaId: 'e1', fileId: 'f1'),
      offline: () => false,
    );
    expect(
      session.episodeLocation(
        episodeId: 'e2',
        fileId: 'f2',
        title: 'Invented Series - S01E02',
        seasonNumber: 1,
        showId: 's1',
      ),
      '/player/episode/e2?fileId=f2'
      '&title=${Uri.encodeComponent('Invented Series - S01E02')}'
      '&showId=s1&seasonNumber=1',
    );
  });
}
