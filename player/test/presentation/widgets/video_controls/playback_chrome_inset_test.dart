// Pins a LAYOUT CONTRACT: how a `SafeArea` responds when the ambient
// `MediaQuery` carries a reserved top strip, and that a full-bleed layer
// outside that `SafeArea` is unaffected by it. `_host` below reproduces
// `playback_chrome.dart`'s shape — a full-bleed surface behind a
// `SafeArea`-wrapped chrome stack — rather than mounting the real player
// screen, which needs a live player controller and platform channels this
// suite does not construct. That means this file proves the contract
// `SafeArea` already honours, not that `playback_chrome.dart`'s own tree
// still matches this shape; a widget test that mounts it directly would be
// needed to catch that kind of drift.

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
        'the video surface stays full-bleed, because it sits outside the '
        'SafeArea; a change that inset it would letterbox every video',
        (tester) async {
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
