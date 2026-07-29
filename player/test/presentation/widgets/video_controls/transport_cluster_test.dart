import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/video_controls/control_button.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  group('TransportSurface', () {
    testWidgets('omits episode buttons when no callbacks are given',
        (tester) async {
      await tester.pumpWidget(
        _host(const TransportSurface(isPlaying: false)),
      );

      expect(find.byKey(TransportSurface.previousEpisodeKey), findsNothing);
      expect(find.byKey(TransportSurface.nextEpisodeKey), findsNothing);
      expect(find.byKey(TransportSurface.playPauseKey), findsOneWidget);
    });

    testWidgets('shows episode buttons when callbacks are given',
        (tester) async {
      await tester.pumpWidget(
        _host(
          TransportSurface(
            isPlaying: false,
            onPreviousEpisode: () {},
            onNextEpisode: () {},
          ),
        ),
      );

      expect(find.byKey(TransportSurface.previousEpisodeKey), findsOneWidget);
      expect(find.byKey(TransportSurface.nextEpisodeKey), findsOneWidget);
    });

    testWidgets('play is 1.25x its skip neighbours, not 1.7x', (tester) async {
      await tester.pumpWidget(
        _host(const TransportSurface(isPlaying: false)),
      );

      final play = tester.widget<ControlButton>(
        find.byKey(TransportSurface.playPauseKey),
      );
      final skip = tester.widget<ControlButton>(
        find.byKey(TransportSurface.back10Key),
      );

      expect(play.iconSize, 30);
      expect(skip.iconSize, 24);
      expect(play.iconSize / skip.iconSize, closeTo(1.25, 0.01));
    });

    testWidgets('every target meets the 44px minimum', (tester) async {
      await tester.pumpWidget(
        _host(
          TransportSurface(
            isPlaying: false,
            onPreviousEpisode: () {},
            onNextEpisode: () {},
          ),
        ),
      );

      for (final key in <Key>[
        TransportSurface.previousEpisodeKey,
        TransportSurface.back10Key,
        TransportSurface.playPauseKey,
        TransportSurface.forward10Key,
        TransportSurface.nextEpisodeKey,
      ]) {
        final button = tester.widget<ControlButton>(find.byKey(key));
        expect(button.size, greaterThanOrEqualTo(44), reason: '$key');
      }
    });

    testWidgets('swaps glyph between play and pause', (tester) async {
      await tester.pumpWidget(
        _host(const TransportSurface(isPlaying: false)),
      );
      expect(
        tester
            .widget<ControlButton>(find.byKey(TransportSurface.playPauseKey))
            .icon,
        Icons.play_arrow_rounded,
      );

      await tester.pumpWidget(
        _host(const TransportSurface(isPlaying: true)),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ControlButton>(find.byKey(TransportSurface.playPauseKey))
            .icon,
        Icons.pause_rounded,
      );
    });

    testWidgets(
        'find.byKey(playPauseKey) resolves to exactly one ControlButton '
        'once the cross-fade settles, even though both the outgoing and '
        'incoming children are briefly mounted mid-transition', (tester) async {
      await tester.pumpWidget(
        _host(const TransportSurface(isPlaying: false)),
      );

      await tester.pumpWidget(
        _host(const TransportSurface(isPlaying: true)),
      );
      // Pump a partial frame so both the outgoing and incoming
      // AnimatedSwitcher children are briefly alive in the tree at once. Both
      // carry the *same* literal playPauseKey (only the KeyedSubtree wrapper
      // around each is uniquely keyed by isPlaying, which is what lets
      // AnimatedSwitcher tell them apart internally) so this is expected to
      // transiently resolve to two widgets, not one.
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        find.byKey(TransportSurface.playPauseKey),
        findsNWidgets(2),
        reason: 'both cross-fade children are mounted mid-transition and '
            'share the same static key; this is expected, not a bug',
      );

      // Once settled, only the incoming child remains, so the key resolves
      // unambiguously again — this is the guarantee callers (goldens, other
      // tests) actually rely on.
      await tester.pumpAndSettle();
      expect(find.byKey(TransportSurface.playPauseKey), findsOneWidget);
      expect(
        tester
            .widget<ControlButton>(find.byKey(TransportSurface.playPauseKey))
            .icon,
        Icons.pause_rounded,
      );
    });

    testWidgets('fires its callbacks', (tester) async {
      var back = false, forward = false, toggled = false;
      await tester.pumpWidget(
        _host(
          TransportSurface(
            isPlaying: false,
            onBack10: () => back = true,
            onForward10: () => forward = true,
            onPlayPause: () => toggled = true,
          ),
        ),
      );

      await tester.tap(find.byKey(TransportSurface.back10Key));
      await tester.tap(find.byKey(TransportSurface.forward10Key));
      await tester.tap(find.byKey(TransportSurface.playPauseKey));

      expect(back, isTrue);
      expect(forward, isTrue);
      expect(toggled, isTrue);
    });

    testWidgets(
        'targets stay left-to-right ordered with uniform 8px gaps, '
        'with or without episode buttons', (tester) async {
      // Without episode buttons: back10, play, forward10 in order with 8px
      // gaps between each hit-target edge.
      await tester.pumpWidget(
        _host(const TransportSurface(isPlaying: false)),
      );

      final backRect = tester.getRect(find.byKey(TransportSurface.back10Key));
      final playRect =
          tester.getRect(find.byKey(TransportSurface.playPauseKey));
      final forwardRect =
          tester.getRect(find.byKey(TransportSurface.forward10Key));

      expect(backRect.right, lessThan(playRect.left));
      expect(playRect.right, lessThan(forwardRect.left));
      expect(playRect.left - backRect.right, closeTo(8, 0.5));
      expect(forwardRect.left - playRect.right, closeTo(8, 0.5));

      // With episode buttons: prev sits left of back10 and next sits right of
      // forward10, each separated by the same 8px gap, and the whole row
      // stays centred (the added prev/next mass is symmetric).
      await tester.pumpWidget(
        _host(
          TransportSurface(
            isPlaying: false,
            onPreviousEpisode: () {},
            onNextEpisode: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      final prevRect =
          tester.getRect(find.byKey(TransportSurface.previousEpisodeKey));
      final backRect2 = tester.getRect(find.byKey(TransportSurface.back10Key));
      final playRect2 =
          tester.getRect(find.byKey(TransportSurface.playPauseKey));
      final forwardRect2 =
          tester.getRect(find.byKey(TransportSurface.forward10Key));
      final nextRect =
          tester.getRect(find.byKey(TransportSurface.nextEpisodeKey));

      expect(prevRect.right, lessThan(backRect2.left));
      expect(backRect2.right, lessThan(playRect2.left));
      expect(playRect2.right, lessThan(forwardRect2.left));
      expect(forwardRect2.right, lessThan(nextRect.left));

      expect(backRect2.left - prevRect.right, closeTo(8, 0.5));
      expect(playRect2.left - backRect2.right, closeTo(8, 0.5));
      expect(forwardRect2.left - playRect2.right, closeTo(8, 0.5));
      expect(nextRect.left - forwardRect2.right, closeTo(8, 0.5));

      // The row is symmetric about its own centre: prev/next add equal
      // widths on either side, so the play button's centre doesn't shift.
      expect(
        (playRect2.center.dx - prevRect.left) -
            (nextRect.right - playRect2.center.dx),
        closeTo(0, 0.5),
      );
    });
  });
}
