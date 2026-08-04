// Regression guard for the letterboxing defect: `PlayerScreen.build` used to
// wrap its whole body — including the media_kit `Video` — in a bare
// `SafeArea`. That was a no-op while `WindowChromeInset` never touched
// `MediaQuery.padding.top`, but once it started folding `kMacTitleBarOverlap`
// in on macOS windowed, the bare `SafeArea` ate that strip a second time,
// pushing the video down by 28pt and putting a black band above every video.
// It compounds: `NativePlayerWindowSizer` then snaps the window to the
// video's aspect ratio *without* that 28pt, so media_kit adds side pillars
// too.
//
// This exercises `PlayerScreen.playerFrame` directly — the same
// `@visibleForTesting` seam `_PlayerScreenState.build` routes through (see
// player_screen.dart) — rather than mounting the full screen, which needs a
// live player controller and platform channels this suite does not
// construct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/presentation/screens/player/player_screen.dart';

const Key _childKey = Key('player-frame-child');

void main() {
  group('PlayerScreen.playerFrame under a reserved window chrome strip', () {
    testWidgets(
        'the child (the video surface, in production) stays flush with the '
        'top of the frame, not pushed down by the macOS title bar strip',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              padding: EdgeInsets.only(top: kMacTitleBarOverlap),
            ),
            child: PlayerScreen.playerFrame(
              child: const SizedBox(
                key: _childKey,
                height: 100,
                width: 100,
              ),
            ),
          ),
        ),
      );

      expect(tester.getRect(find.byKey(_childKey)).top, 0);
    });
  });
}
