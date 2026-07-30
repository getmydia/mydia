import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/presentation/widgets/gesture_controls.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

/// A [PlatformPlayer] that never touches native mpv/web bindings — safe to
/// construct inside `flutter test`. Every mutating call records what it was
/// asked to do instead of throwing `UnimplementedError` (the base class's
/// default for every method), which is all [GestureControls] and
/// [PlaybackChrome] need to build and to react to gestures.
class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  Duration? lastSeek;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> seek(Duration duration) async {
    lastSeek = duration;
  }
}

double _opacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(ChromeVisibility.contentKey),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

void main() {
  group('GestureControls + PlaybackChrome composition', () {
    // Task 12 flagged forward: ChromeVisibility's background tap-to-toggle
    // catcher is a full-screen, opaque GestureDetector painted as
    // PlaybackChrome's topmost layer. In the real player_screen.dart,
    // PlaybackChrome is never a Stack *sibling* of GestureControls — it is
    // the `controls` builder media_kit's Video renders via
    // `Positioned.fill(child: controls!.call(this))` inside Video's own
    // `Stack(fit: StackFit.expand)`, and that whole Video widget is what
    // GestureControls wraps as its `child`. This tree mirrors that shape
    // exactly (SizedBox.expand -> Stack(expand) -> [stand-in texture,
    // Positioned.fill(PlaybackChrome)] -> wrapped by GestureControls) so the
    // hit-testing story matches production, not a simplified stand-in.
    Widget host(Player player) => MaterialApp(
          home: Scaffold(
            body: SizedBox.expand(
              child: GestureControls(
                player: player,
                child: SizedBox.expand(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Stand-in for the video texture: it never registers a
                      // gesture/mouse hit, exactly like media_kit's Texture.
                      const SizedBox.shrink(),
                      Positioned.fill(child: PlaybackChrome(player: player)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

    testWidgets(
        'a double-tap on an empty region still reaches GestureControls '
        'and seeks forward, despite ChromeVisibility\'s opaque background '
        'tap-catcher sitting on top of it', (tester) async {
      final fake = _FakePlatformPlayer();
      fake.state = fake.state.copyWith(duration: const Duration(minutes: 5));
      final player = Player(platformPlayer: fake);
      addTearDown(player.dispose);

      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      // Right half, mid-height: clear of the top bar (anchored top) and the
      // bottom panel (anchored bottom, at most 48+panel-height tall), so the
      // tap lands on ChromeVisibility's empty background catcher, not a
      // control — the exact scenario that would be swallowed if the two
      // gesture layers didn't compose correctly.
      final size = tester.getSize(find.byType(GestureControls));
      final rightMid = Offset(size.width * 0.9, size.height / 2);

      await tester.tapAt(rightMid);
      await tester.pump(kDoubleTapMinTime);
      await tester.tapAt(rightMid);
      await tester.pumpAndSettle();
      // Flush GestureControls' own seek-feedback auto-hide timer
      // (Future.delayed(500ms)) so no pending timer survives the test.
      await tester.pump(const Duration(milliseconds: 600));

      expect(
        fake.lastSeek,
        const Duration(seconds: 10),
        reason: 'GestureControls double-tap-right must still seek forward '
            'through PlaybackChrome\'s opaque tap catcher',
      );
    });

    testWidgets(
        'a single tap on an empty region still toggles chrome visibility '
        'through GestureControls\' translucent wrapper', (tester) async {
      final fake = _FakePlatformPlayer();
      final player = Player(platformPlayer: fake);
      addTearDown(player.dispose);

      await tester.pumpWidget(host(player));
      await tester.pumpAndSettle();

      expect(_opacity(tester), 1.0);

      final size = tester.getSize(find.byType(GestureControls));
      final center = Offset(size.width / 2, size.height / 2);

      await tester.tapAt(center);
      // A lone tap only resolves once the ancestor double-tap recognizer
      // (GestureControls) gives up waiting for a second tap.
      await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(
        _opacity(tester),
        0.0,
        reason: 'the background tap-to-toggle must still fire through '
            'GestureControls\' translucent GestureDetector',
      );
    });
  });
}
