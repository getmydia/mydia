// Coverage for the affordance that recovers a browser's autoplay refusal.
//
// The branch in `_onPlaybackError` that raises this overlay cannot be driven
// from `player_screen_test_harness.dart`: reaching it needs a live media_kit
// `Player` to emit on `stream.error`, and building one under `flutter test`
// fails for want of `MediaKit.ensureInitialized` (see
// `player_screen_cast_start_failure_test.dart`'s header). What *is* pinned
// here is the half that matters at the point of contact — that a tap anywhere
// on the video starts playback, and that the tap cannot fall through to the
// seek gestures underneath.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/tap_to_play_overlay.dart';

void main() {
  /// Mounts the overlay over a stand-in for the gesture controls it covers,
  /// so a tap that leaks through is observable rather than silently ignored.
  Future<void> pumpOverlay(
    WidgetTester tester, {
    required VoidCallback onPlay,
    required VoidCallback onUnderlayTap,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: onUnderlayTap,
                behavior: HitTestBehavior.opaque,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            TapToPlayOverlay(onPlay: onPlay),
          ],
        ),
      ),
    );
  }

  testWidgets('a tap on the glyph starts playback', (tester) async {
    var plays = 0;
    var underlayTaps = 0;

    await pumpOverlay(
      tester,
      onPlay: () => plays++,
      onUnderlayTap: () => underlayTaps++,
    );

    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();

    expect(plays, 1);
    expect(underlayTaps, 0);
  });

  testWidgets('a tap anywhere on the video starts playback', (tester) async {
    var plays = 0;
    var underlayTaps = 0;

    await pumpOverlay(
      tester,
      onPlay: () => plays++,
      onUnderlayTap: () => underlayTaps++,
    );

    // The top-left corner: as far from the glyph as this surface goes, and
    // squarely inside the left half, where `GestureControls` would otherwise
    // read a tap as a seek.
    await tester.tapAt(const Offset(20, 20));
    await tester.pump();

    expect(
      plays,
      1,
      reason: 'the whole picture is the target — asking a viewer to find a '
          'glyph is the friction this overlay exists to remove',
    );
    expect(
      underlayTaps,
      0,
      reason: 'a tap that reaches the gesture controls underneath would seek '
          'a video that has not started',
    );
  });

  testWidgets('says what it is waiting for', (tester) async {
    await pumpOverlay(tester, onPlay: () {}, onUnderlayTap: () {});

    expect(find.text('Tap to play'), findsOneWidget);
    expect(
      find.textContaining('browser'),
      findsOneWidget,
      reason: 'naming the browser as the thing holding playback up is what '
          'keeps this from reading as another failure',
    );
  });
}
