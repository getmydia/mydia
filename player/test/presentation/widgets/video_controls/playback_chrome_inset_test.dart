// Pins the LAYOUT CONTRACT for `PlayerTopBarSlot`: how the player's top bar
// is placed when a reserved window-chrome band is in play, and how it falls
// back to the old fixed inset when there is none. `_host` below reproduces
// `playback_chrome.dart`'s shape for the chrome layer only, a
// `SafeArea(top: false, ...)` wrapping a `Stack` the top bar is positioned
// into, rather than mounting the real player screen, which needs a live
// player controller and platform channels this suite does not construct.
//
// `PlayerTopBarSlot` is also what `player_screen.dart`'s
// `_withCastAffordance` builds the loading/error cast pill through (see
// `player_screen_frame_inset_test.dart` for the outer frame contract this
// sits inside), so a middle group here proves that seam directly: two very
// different `ChromeTopBar` configurations, placed through the same slot,
// land their cast pill on the exact same rect.
//
// The final group mounts the real `PlaybackChrome`, not a mirror: moving the
// top bar out of `SafeArea` (so it can be placed independently, per the
// class doc above) must not change what every *other* child of that stack
// gets from its own, still-all-sides `SafeArea`. A `SafeArea(top: false)`
// wrapping everything, which is what an earlier version of this file had, is
// exactly the regression that group is pinned against: it would leave the
// centre play button and the bottom panel un-inset from the platform's top
// safe-area padding (a phone's status bar or notch) while still correctly
// consuming left/right/bottom, an easy thing to miss since only one edge is
// wrong.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/core/player/stream_timeline.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';
import 'package:player/presentation/widgets/video_controls/chrome_subtitle_lift.dart';
import 'package:player/presentation/widgets/video_controls/chrome_top_bar.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';
import 'package:player/presentation/widgets/window_chrome/window_title_row.dart';

const Key _videoSurfaceKey = Key('stand-in-video-surface');

/// A [PlatformPlayer] that never touches native mpv/web bindings, safe to
/// construct inside `flutter test`. Same shape as
/// `playback_chrome_episode_nav_test.dart`'s fake (kept separate, not
/// shared, since neither file exports it and duplicating ~15 lines is
/// cheaper than introducing a new shared test-only import).
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

const _macInsets = WindowChromeInsets(
  height: kMacTitleBarOverlap,
  leading: kMacTrafficLightsWidth,
  trailing: 0,
);

/// Mirrors the structure of `playback_chrome.dart`: a full-bleed surface at
/// the back, and the chrome (here, just the top bar slot) in a
/// `SafeArea(top: false, ...)` on top of it, under whichever
/// `WindowChromeInsets` the caller wants to simulate.
Widget _host(
  Widget topBarSlot, {
  required WindowChromeInsets insets,
  required double paddingTop,
}) =>
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          // `MediaQuery.of(context).copyWith`, not a bare `MediaQueryData(...)`:
          // the latter defaults every other field, including `size`, to its
          // class default (`Size.zero`), which would keep the macOS group's
          // resized `tester.view.physicalSize` from ever reaching
          // `Breakpoints.isDesktop` -- see `chromeHost` below, which has the
          // same fix for the same reason.
          data: MediaQuery.of(context)
              .copyWith(padding: EdgeInsets.only(top: paddingTop)),
          child: WindowChromeInsets.scope(
            insets: insets,
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
                    top: false,
                    child: Stack(children: [topBarSlot]),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  group('PlayerTopBarSlot inside the macOS title bar band', () {
    // A desktop-tier width so `WindowTitleRow.endGutter` resolves to the
    // desktop gutter rather than the mobile fallback, matching how a
    // windowed macOS build (which is what carries these insets at all) is
    // actually sized.
    const width = 1280.0;
    const height = 800.0;

    testWidgets(
        'the back pill clears the traffic lights and sits level '
        'with them', (tester) async {
      tester.view.physicalSize = const Size(width, height);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          PlayerTopBarSlot(child: ChromeTopBar(onBack: () {})),
          insets: _macInsets,
          paddingTop: kMacTitleBarOverlap,
        ),
      );

      final gutter =
          WindowTitleRow.endGutter(tester.element(find.byType(ChromeTopBar)));
      final back = tester.getRect(find.byKey(ChromeTopBar.backKey));

      expect(back.left, greaterThanOrEqualTo(kMacTrafficLightsWidth + gutter));
      // The traffic lights sit at y 13-26 (see `kMacTitleBarOverlap`'s
      // dartdoc), a vertical centre of ~20.
      expect((back.top + back.bottom) / 2, closeTo(20, 1));
    });

    testWidgets('the cast pill sits endGutter from the trailing edge',
        (tester) async {
      tester.view.physicalSize = const Size(width, height);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          PlayerTopBarSlot(
            child: ChromeTopBar(
              castAction: const Icon(Icons.cast),
              onCastTap: () {},
            ),
          ),
          insets: _macInsets,
          paddingTop: kMacTitleBarOverlap,
        ),
      );

      final gutter =
          WindowTitleRow.endGutter(tester.element(find.byType(ChromeTopBar)));
      final cast = tester.getRect(find.byKey(ChromeTopBar.castKey));

      expect(cast.right, closeTo(width - gutter, 0.5));
    });
  });

  group('PlayerTopBarSlot with no window chrome to clear', () {
    testWidgets(
        "today's mobile position is unchanged: padding.top + 16, unaffected "
        'by the chrome no longer consuming padding.top itself', (tester) async {
      await tester.pumpWidget(
        _host(
          PlayerTopBarSlot(child: ChromeTopBar(onBack: () {})),
          insets: WindowChromeInsets.zero,
          paddingTop: 24,
        ),
      );

      final back = tester.getRect(find.byKey(ChromeTopBar.backKey));
      expect(back.top, 24 + 16);
    });

    testWidgets(
        'CONTROL: the stand-in surface stays full-bleed within this shape, '
        'because it sits outside the SafeArea', (tester) async {
      await tester.pumpWidget(
        _host(
          PlayerTopBarSlot(child: ChromeTopBar(onBack: () {})),
          insets: WindowChromeInsets.zero,
          paddingTop: 24,
        ),
      );

      expect(tester.getRect(find.byKey(_videoSurfaceKey)).top, 0);
    });
  });

  group(
      'PlayerTopBarSlot keeps the loading/error cast pill on the playing '
      "state's spot", () {
    Future<Rect> castRectFor(
      WidgetTester tester, {
      required Widget chromeTopBar,
      required WindowChromeInsets insets,
      required double paddingTop,
    }) async {
      await tester.pumpWidget(
        _host(
          PlayerTopBarSlot(child: chromeTopBar),
          insets: insets,
          paddingTop: paddingTop,
        ),
      );
      return tester.getRect(find.byKey(ChromeTopBar.castKey));
    }

    testWidgets('matches under the macOS title bar band', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // The playing state: back pill, a title, and a cast pill.
      final playing = await castRectFor(
        tester,
        chromeTopBar: ChromeTopBar(
          title: 'Fictional Show S01E02',
          onBack: () {},
          castAction: const Icon(Icons.cast),
          onCastTap: () {},
        ),
        insets: _macInsets,
        paddingTop: kMacTitleBarOverlap,
      );

      // `_withCastAffordance`'s exact shape: no back pill, no title, cast
      // only.
      final loadingOrError = await castRectFor(
        tester,
        chromeTopBar: ChromeTopBar(
          showBack: false,
          castAction: const Icon(Icons.cast),
          onCastTap: () {},
        ),
        insets: _macInsets,
        paddingTop: kMacTitleBarOverlap,
      );

      expect(loadingOrError, playing);
    });

    testWidgets('matches with no window chrome to clear', (tester) async {
      final playing = await castRectFor(
        tester,
        chromeTopBar: ChromeTopBar(
          title: 'Fictional Show S01E02',
          onBack: () {},
          castAction: const Icon(Icons.cast),
          onCastTap: () {},
        ),
        insets: WindowChromeInsets.zero,
        paddingTop: 24,
      );

      final loadingOrError = await castRectFor(
        tester,
        chromeTopBar: ChromeTopBar(
          showBack: false,
          castAction: const Icon(Icons.cast),
          onCastTap: () {},
        ),
        insets: WindowChromeInsets.zero,
        paddingTop: 24,
      );

      expect(loadingOrError, playing);
    });
  });

  group('PlaybackChrome: the rest of the chrome keeps its old SafeArea insets',
      () {
    late Player player;

    setUp(() {
      player = Player(platformPlayer: _FakePlatformPlayer());
    });

    tearDown(() => player.dispose());

    // A nonzero bottom is load-bearing: the content and panel assertions
    // below check `rect.bottom` against `height - padding.bottom`, which a
    // zero bottom cannot tell apart from a `PlaybackChrome` that dropped the
    // bottom `SafeArea` inset entirely -- both give the same rect.
    const padding = EdgeInsets.fromLTRB(44, 24, 44, 20);
    const width = 1200.0;
    const height = 700.0;

    // `MediaQuery.of(context).copyWith(padding: padding)`, not a bare
    // `MediaQueryData(padding: padding)`: the latter defaults every other
    // field, including `size`, to its class default (`Size.zero`), which
    // would make `PanelMetrics.resolve`'s width-driven `bottomOffset` branch
    // in `PlaybackChrome.build` resolve against 0 instead of the resized
    // view. `copyWith` keeps the real, resized `size` and overrides only
    // `padding`.
    Widget chromeHost() => MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(padding: padding),
              child: Scaffold(
                body: PlaybackChrome(
                  player: player,
                  timeline: StreamTimeline.zero,
                  onSeekToReal: (_) async {},
                ),
              ),
            ),
          ),
        );

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(width, height);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(chromeHost());
      await tester.pumpAndSettle();
    }

    testWidgets(
        'the safe-area content layer keeps the box a single all-sides '
        'SafeArea always gave it, consumed on every side and not just '
        'left/right/bottom', (tester) async {
      await pump(tester);

      final content = tester.getRect(find.byKey(PlaybackChrome.safeContentKey));
      expect(content.left, padding.left);
      expect(content.top, padding.top);
      expect(content.right, width - padding.right);
      expect(content.bottom, height - padding.bottom);
    });

    testWidgets(
        'the bottom transport panel keeps its old rect, unaffected by the '
        'top bar now sitting outside the SafeArea', (tester) async {
      await pump(tester);

      final panel = tester.getRect(find.byType(ChromeSubtitleLift));
      // Desktop-tier width (>= 900), matching the resized view above, so
      // `bottomOffset` is 48 -- see `PanelMetrics.resolve`.
      final metrics = PanelMetrics.resolve(width: width, touchPrimary: false);

      expect(panel.left, padding.left);
      expect(panel.right, width - padding.right);
      expect(panel.bottom, height - padding.bottom - metrics.bottomOffset);
    });

    testWidgets(
        'the top bar still clears the same left inset the old SafeArea gave '
        "it, proving PlayerTopBarSlot's own left/right padding compensation "
        'end to end against the real widget', (tester) async {
      await pump(tester);

      final back = tester.getRect(find.byKey(ChromeTopBar.backKey));
      expect(back.left, padding.left + 16);
    });
  });
}
