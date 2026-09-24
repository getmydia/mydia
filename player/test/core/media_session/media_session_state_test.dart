import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/media_session/media_session_state.dart';
import 'package:player/native/lib.dart';

import 'fakes.dart';

void main() {
  group('mediaSessionStateFrom', () {
    test('no snapshot is the stopped state', () {
      expect(mediaSessionStateFrom(null), MediaSessionState.stopped);
    });

    test('maps a playing movie', () {
      final state = mediaSessionStateFrom(
        buildSnapshot(),
        metadata: const NowPlayingMetadata(subtitle: '2031'),
        artworkPath: '/cache/poster.jpg',
      );
      expect(state.status, MediaSessionStatus.playing);
      expect(state.trackId, 'item-1');
      expect(state.title, 'The Glass Orchard');
      expect(state.subtitle, '2031');
      expect(state.artworkPath, '/cache/poster.jpg');
      expect(state.position, const Duration(seconds: 10));
      expect(state.duration, const Duration(minutes: 90));
      expect(state.volume, 0.8);
      expect(state.canSeek, isTrue);
      expect(state.canGoNext, isFalse);
      expect(state.canGoPrevious, isFalse);
    });

    test('an episode uses its own id and the resolved episode title', () {
      final state = mediaSessionStateFrom(
        buildSnapshot(
          episodeId: 'ep-7',
          title: 'Harbor Lights - S02E05',
          nextPrevious: true,
        ),
        metadata: const NowPlayingMetadata(
          title: 'The Lantern Keeper',
          subtitle: 'Harbor Lights · S2E5',
        ),
      );
      expect(state.trackId, 'ep-7');
      expect(state.title, 'The Lantern Keeper');
      expect(state.subtitle, 'Harbor Lights · S2E5');
      expect(state.canGoNext, isTrue);
      expect(state.canGoPrevious, isTrue);
    });

    test('muted reports zero volume; unknown volume reports full', () {
      expect(mediaSessionStateFrom(buildSnapshot(muted: true)).volume, 0.0);
      expect(mediaSessionStateFrom(buildSnapshot(volume: null)).volume, 1.0);
    });

    test('player states map onto the three MPRIS statuses', () {
      MediaSessionStatus statusOf(FlutterPlaybackState s) =>
          mediaSessionStateFrom(buildSnapshot(state: s)).status;
      expect(
          statusOf(FlutterPlaybackState.playing), MediaSessionStatus.playing);
      expect(
          statusOf(FlutterPlaybackState.buffering), MediaSessionStatus.playing);
      expect(statusOf(FlutterPlaybackState.paused), MediaSessionStatus.paused);
      expect(statusOf(FlutterPlaybackState.loading), MediaSessionStatus.paused);
      expect(statusOf(FlutterPlaybackState.idle), MediaSessionStatus.stopped);
      expect(statusOf(FlutterPlaybackState.ended), MediaSessionStatus.stopped);
      expect(statusOf(FlutterPlaybackState.error), MediaSessionStatus.stopped);
    });

    test('no duration means not seekable', () {
      final state =
          mediaSessionStateFrom(buildSnapshot(duration: Duration.zero));
      expect(state.canSeek, isFalse);
    });

    test('value equality', () {
      expect(mediaSessionStateFrom(buildSnapshot()),
          mediaSessionStateFrom(buildSnapshot()));
      expect(mediaSessionStateFrom(buildSnapshot()),
          isNot(mediaSessionStateFrom(buildSnapshot(title: 'Other'))));
    });
  });
}
