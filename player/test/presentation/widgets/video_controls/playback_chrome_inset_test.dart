// Pins a LAYOUT CONTRACT: how a `SafeArea` responds when the ambient
// `MediaQuery` carries a reserved top strip, and that a full-bleed layer
// outside that `SafeArea` is unaffected by it. `_host` below reproduces
// `playback_chrome.dart`'s shape — a full-bleed surface behind a
// `SafeArea`-wrapped chrome stack — rather than mounting the real player
// screen, which needs a live player controller and platform channels this
// suite does not construct.
//
// IMPORTANT: `_host`'s stand-in surface sits directly under the strip, with
// no outer `SafeArea` above it. Production is not shaped that way:
// `PlayerScreen.build` wraps its whole body — this chrome included — in
// `PlayerScreen.playerFrame`'s own `SafeArea(top: false, ...)` first. That
// means this file proves the contract `SafeArea` already honours in
// isolation — that a full-bleed layer outside a `SafeArea` is unaffected by
// a reserved strip, and that the chrome inside one is pushed clear of it —
// not that `playback_chrome.dart`'s real position inside `PlayerScreen`
// still matches this shape. It would stay green even if `playerFrame` regressed
// to a bare `SafeArea` and letterboxed every video, because `_host` never
// reproduces that outer frame. `player_screen_frame_inset_test.dart` is the
// test that actually guards production: it exercises `PlayerScreen
// .playerFrame` itself and would fail on that regression.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/presentation/widgets/video_controls/chrome_top_bar.dart';

const Key _videoSurfaceKey = Key('stand-in-video-surface');

/// Mirrors the structure of `playback_chrome.dart`: a full-bleed surface at the
/// back, and the chrome in a `SafeArea` on top of it. The point of the test is
/// that a reserved chrome strip moves the second and not the first.
Widget _host(Widget chrome) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.only(top: kMacTitleBarOverlap),
        ),
        child: Scaffold(
          body: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(
                  key: _videoSurfaceKey,
                  color: Colors.black,
                ),
              ),
              SafeArea(
                child: Stack(
                  children: [
                    Positioned(top: 16, left: 16, right: 16, child: chrome),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

void main() {
  group('playback chrome under a reserved window chrome strip', () {
    testWidgets('the back pill clears the traffic light strip', (tester) async {
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            tier: PlayerGlassTier.full,
            onBack: () {},
          ),
        ),
      );

      final back = tester.getRect(find.byKey(ChromeTopBar.backKey));
      expect(back.top, greaterThanOrEqualTo(kMacTitleBarOverlap));
    });

    testWidgets(
        'CONTROL: the stand-in surface stays full-bleed within this shape, '
        'because it sits outside the SafeArea — but see the file header: '
        'this does not prove playback_chrome.dart is actually positioned '
        'this way inside the real PlayerScreen frame', (tester) async {
      await tester.pumpWidget(
        _host(
          ChromeTopBar(
            tier: PlayerGlassTier.full,
            onBack: () {},
          ),
        ),
      );

      expect(tester.getRect(find.byKey(_videoSurfaceKey)).top, 0);
    });
  });
}
