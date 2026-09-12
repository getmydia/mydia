import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
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

    testWidgets(
        'compact renders only play/pause, ignoring seek and episode-nav '
        'callbacks entirely — used below the mobile breakpoint (see '
        "compact's own dartdoc)", (tester) async {
      await tester.pumpWidget(
        _host(
          TransportSurface(
            isPlaying: false,
            onBack10: () {},
            onForward10: () {},
            onPreviousEpisode: () {},
            onNextEpisode: () {},
            compact: true,
          ),
        ),
      );

      expect(find.byKey(TransportSurface.playPauseKey), findsOneWidget);
      expect(find.byKey(TransportSurface.back10Key), findsNothing);
      expect(find.byKey(TransportSurface.forward10Key), findsNothing);
      expect(find.byKey(TransportSurface.previousEpisodeKey), findsNothing);
      expect(find.byKey(TransportSurface.nextEpisodeKey), findsNothing);

      // Still the same 40px play/pause button, not some other size.
      //
      // 40, not the original 48: the transport cluster was compacted so a
      // 4th secondary button fits below the desktop tier. See
      // transport_cluster.dart's `gap` dartdoc.
      final button = tester.widget<ControlButton>(
        find.byKey(TransportSurface.playPauseKey),
      );
      expect(button.size, 40);
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

    testWidgets('play is 1.2x its skip neighbours, not 1.7x', (tester) async {
      // Play/skip iconSizes dropped from 30/24 to 24/20 alongside the
      // transport cluster's compaction (48/44px buttons to 40/36px), but the
      // proportion between them is deliberately preserved at roughly the
      // same ratio as before (1.25x -> 1.2x), not left at the old absolute
      // sizes. See transport_cluster.dart's `gap` dartdoc.
      await tester.pumpWidget(
        _host(const TransportSurface(isPlaying: false)),
      );

      final play = tester.widget<ControlButton>(
        find.byKey(TransportSurface.playPauseKey),
      );
      final skip = tester.widget<ControlButton>(
        find.byKey(TransportSurface.back10Key),
      );

      expect(play.iconSize, 24);
      expect(skip.iconSize, 20);
      expect(play.iconSize / skip.iconSize, closeTo(1.2, 0.01));
    });

    testWidgets('every target meets the 36px minimum', (tester) async {
      // 36, not ControlButton's 44px default: the transport cluster was
      // compacted so a 4th secondary button fits below the desktop tier.
      // See transport_cluster.dart's `gap` dartdoc.
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
        expect(button.size, greaterThanOrEqualTo(36), reason: '$key');
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
        'the play/pause button stays one ControlButton across the cross-fade, '
        'and the supplied node keeps primary focus throughout', (tester) async {
      final playPauseFocusNode = FocusNode(debugLabel: 'play-pause');
      addTearDown(playPauseFocusNode.dispose);

      await tester.pumpWidget(
        _host(
          TransportSurface(
            isPlaying: false,
            onPlayPause: () {},
            playPauseFocusNode: playPauseFocusNode,
          ),
        ),
      );

      playPauseFocusNode.requestFocus();
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus,
        same(playPauseFocusNode),
        reason: 'precondition: the button owns focus before the toggle',
      );

      await tester.pumpWidget(
        _host(
          TransportSurface(
            isPlaying: true,
            onPlayPause: () {},
            playPauseFocusNode: playPauseFocusNode,
          ),
        ),
      );
      // Pump a partial frame so the glyph cross-fade is running: both the
      // outgoing and incoming glyph are alive in the tree at once.
      await tester.pump(const Duration(milliseconds: 40));

      expect(
        find.byKey(TransportSurface.playPauseKey),
        findsOneWidget,
        reason: 'the cross-fade animates the glyph inside the button, so this '
            'key resolves to exactly one ControlButton at every point in the '
            'transition — there is no window with two live buttons, and so no '
            'window with two owners of the caller-supplied focus node',
      );
      // The invariant the finding is about: one node, one owner. Two live
      // ControlButtons would each hand playPauseFocusNode to a FocusHighlight
      // of their own, and the focus system keeps only the most recent
      // attachment — so the outgoing button's ring and activation would
      // silently stop tracking the node for the length of the fade.
      expect(
        tester
            .widgetList<FocusHighlight>(find.byType(FocusHighlight))
            .where((widget) => widget.focusNode == playPauseFocusNode)
            .length,
        1,
        reason: 'exactly one widget may own the caller-supplied node',
      );
      expect(
        find.byIcon(Icons.play_arrow_rounded),
        findsOneWidget,
        reason: 'the outgoing glyph is still alive mid-cross-fade',
      );
      expect(
        find.byIcon(Icons.pause_rounded),
        findsOneWidget,
        reason: 'the incoming glyph is alive mid-cross-fade',
      );
      expect(
        FocusManager.instance.primaryFocus,
        same(playPauseFocusNode),
        reason: 'the supplied node must hold primary focus across the toggle; '
            'asserting identity, not hasFocus, because hasFocus is also true '
            'for an ancestor',
      );

      // Once settled, only the incoming glyph remains, and the key still
      // resolves unambiguously — the guarantee callers (goldens, other tests)
      // rely on.
      await tester.pumpAndSettle();
      expect(find.byKey(TransportSurface.playPauseKey), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
      expect(
        tester
            .widget<ControlButton>(find.byKey(TransportSurface.playPauseKey))
            .icon,
        Icons.pause_rounded,
      );
      expect(
        FocusManager.instance.primaryFocus,
        same(playPauseFocusNode),
        reason: 'the node still owns focus once the cross-fade has settled',
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
        'targets stay left-to-right ordered with uniform 2px gaps, '
        'with or without episode buttons', (tester) async {
      // 2, not the original 8: the transport cluster was compacted so a 4th
      // secondary button fits below the desktop tier. See
      // transport_cluster.dart's `gap` dartdoc.
      //
      // Without episode buttons: back10, play, forward10 in order with 2px
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
      expect(playRect.left - backRect.right, closeTo(2, 0.5));
      expect(forwardRect.left - playRect.right, closeTo(2, 0.5));

      // With episode buttons: prev sits left of back10 and next sits right of
      // forward10, each separated by the same 2px gap, and the whole row
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

      expect(backRect2.left - prevRect.right, closeTo(2, 0.5));
      expect(playRect2.left - backRect2.right, closeTo(2, 0.5));
      expect(forwardRect2.left - playRect2.right, closeTo(2, 0.5));
      expect(nextRect.left - forwardRect2.right, closeTo(2, 0.5));

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
