// Unit coverage for `loadContentIntentForPulledSession`, the mapping behind
// `CastMiniController._pullToLocal`'s "open locally at that position" half
// of Pull. Extracted as a free function for the same reason as
// `player_screen.dart`'s `applyQualityChoice`/`pushToRemoteTarget`: the
// widget path needs a live `CastSessionManager`, a resolved GraphQL client
// and a mounted `GoRouter` to reach this decision, none of which a bare
// unit test can stand up — but the mapping itself needs none of them.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/presentation/widgets/cast_mini_controller.dart';

void main() {
  group('loadContentIntentForPulledSession', () {
    test('carries every field straight across for a movie', () {
      const pulled = PulledSession(
        mediaItemId: 'movie-42',
        episodeId: null,
        position: Duration(minutes: 41),
        selectedAudioTrackId: 'audio-eng',
        selectedSubtitleTrackId: 'sub-fre',
      );

      final intent = loadContentIntentForPulledSession(pulled);

      expect(intent, isNotNull);
      expect(intent!.mediaItemId, 'movie-42');
      expect(intent.episodeId, isNull);
      expect(intent.startAt, const Duration(minutes: 41));
      expect(intent.audioTrack, 'audio-eng');
      expect(intent.subtitleTrack, 'sub-fre');
      expect(intent.autoplay, isTrue,
          reason: 'pulling a session back is always meant to resume it, '
              'never to land on a paused first frame');
    });

    test('carries the episode id across for a show', () {
      const pulled = PulledSession(
        mediaItemId: 'show-1',
        episodeId: 'ep-7',
        position: Duration(seconds: 90),
        selectedAudioTrackId: null,
        selectedSubtitleTrackId: null,
      );

      final intent = loadContentIntentForPulledSession(pulled);

      expect(intent?.mediaItemId, 'show-1');
      expect(intent?.episodeId, 'ep-7');
      expect(intent?.audioTrack, isNull);
      expect(intent?.subtitleTrack, isNull);
    });

    test('returns null when the target had nothing usable to report', () {
      // `PulledSession.mediaItemId`'s own dartdoc: "a caller with nothing to
      // open should treat that as there was nothing to pull, not open an
      // item with no id." This is the caller honoring that.
      const pulled = PulledSession(
        mediaItemId: null,
        episodeId: null,
        position: Duration.zero,
        selectedAudioTrackId: null,
        selectedSubtitleTrackId: null,
      );

      expect(loadContentIntentForPulledSession(pulled), isNull);
    });
  });
}
