// Regression coverage for Task 8's `VideoProgressBar` wiring change: the
// scrubber's commit now calls `onSeekToReal` with a *real* media position
// (computed against the resolved total duration and shifted onto the
// timeline) instead of calling `player.seek` directly. Companion to
// `video_progress_bar_test.dart`, which already proves `ProgressBarSurface`
// itself fires `onSeekTo` exactly once per commit and `onSeekUpdate`
// continuously during the drag (Task 8 Step 4's debounce guarantee) — this
// file only needs to confirm the fraction-to-real-Duration translation one
// level up, in `VideoProgressBar`.
//
// Uses a fake `PlatformPlayer`, not a bare `Player()`: constructing a real
// one requires native mpv/FFI (`NativePlayer`'s constructor calls
// `DynamicLibrary.open` synchronously), unavailable under `flutter test` —
// same reasoning as `gesture_chrome_composition_test.dart`'s fake.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/stream_timeline.dart';
import 'package:player/presentation/widgets/video_controls/video_progress_bar.dart';

class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> seek(Duration duration) async {}
}

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 400, child: child)),
      ),
    );

void main() {
  group('VideoProgressBar real-coordinate seek wiring', () {
    late _FakePlatformPlayer fake;
    late Player player;

    setUp(() {
      fake = _FakePlatformPlayer();
      // A session resumed at 10 minutes in: the player only ever sees the
      // remainder (a still-partial, still-growing local duration), exactly
      // the case `StreamTimeline` exists to correct.
      fake.state = fake.state.copyWith(
        position: const Duration(seconds: 30),
        duration: const Duration(seconds: 300),
        buffer: const Duration(seconds: 60),
      );
      player = Player(platformPlayer: fake);
    });

    tearDown(() => player.dispose());

    testWidgets(
        'committing a scrub calls onSeekToReal with a real position, not '
        'the player-local one', (tester) async {
      Duration? seekTarget;
      var seekCount = 0;

      await tester.pumpWidget(_host(VideoProgressBar(
        player: player,
        // startOffset=600s, resolved runtime=1200s: the player's own 300s
        // duration must never leak into this computation.
        timeline: const StreamTimeline(
          startOffset: Duration(seconds: 600),
          totalDuration: Duration(seconds: 1200),
        ),
        onSeekToReal: (target) async {
          seekTarget = target;
          seekCount++;
        },
      )));
      await tester.pump();

      final rect = tester.getRect(find.byType(VideoProgressBar));
      await tester.tapAt(Offset(rect.left + rect.width * 0.5, rect.center.dy));
      await tester.pump();

      expect(seekCount, 1);
      expect(
        seekTarget,
        const Duration(seconds: 600),
        reason: 'the midpoint of a resolved 1200s runtime is real position '
            "600s — half of the player's own partial 300s duration (150s) "
            'would prove the real-coordinate translation regressed',
      );
    });

    testWidgets(
        'dragging without releasing never calls onSeekToReal — only the '
        'commit at drag end does', (tester) async {
      var seekCount = 0;

      await tester.pumpWidget(_host(VideoProgressBar(
        player: player,
        timeline: const StreamTimeline(
          startOffset: Duration(seconds: 600),
          totalDuration: Duration(seconds: 1200),
        ),
        onSeekToReal: (_) async => seekCount++,
      )));
      await tester.pump();

      final rect = tester.getRect(find.byType(VideoProgressBar));
      final gesture = await tester.startGesture(
        Offset(rect.left + rect.width * 0.1, rect.center.dy),
      );
      addTearDown(() => gesture.removePointer());

      // Clears touch slop and starts the drag.
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(80, 0));
      await tester.pump();

      expect(seekCount, 0,
          reason: 'a restart per drag frame would spawn FFmpeg processes '
              'faster than the server reaps them — onSeekToReal must only '
              'fire on commit, never on the live drag updates');

      await gesture.up();
      await tester.pump();

      expect(seekCount, 1,
          reason: 'the commit at drag end must fire exactly once');
    });
  });
}
