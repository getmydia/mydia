import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/stream_timeline.dart';
import 'package:player/presentation/widgets/video_controls/chrome_subtitle_lift.dart';
import 'package:player/presentation/widgets/video_controls/custom_video_controls.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());
}

class _NoopLift implements SubtitleLift {
  @override
  void apply(double bottom, {required Duration duration}) {}
}

void main() {
  test(
    'playbackChromeBuilder builds a PlaybackChrome from player and lift',
    () {
      final player = Player(platformPlayer: _FakePlatformPlayer());
      final lift = _NoopLift();
      final build = playbackChromeBuilder(
        timeline: StreamTimeline.zero,
        onSeekToReal: (_) async {},
        castAction: null,
        onCastTap: null,
        title: 'Sample',
        audioTrackCount: 2,
      );

      final widget = build(player, lift);

      expect(widget, isA<PlaybackChrome>());
      final chrome = widget as PlaybackChrome;
      expect(chrome.player, same(player));
      expect(chrome.subtitleLift, same(lift));
      expect(chrome.title, 'Sample');
      expect(chrome.audioTrackCount, 2);
    },
  );
}
