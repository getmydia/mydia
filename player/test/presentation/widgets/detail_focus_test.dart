// PlayButton is an InkWell, so it was already a focus stop and Enter already
// worked. What it had no way to show is *that* it was focused: InkWell's
// default focusColor is a faint overlay, and this button paints a solid
// AppColors.primary circle underneath it. Reachable but invisible is worse
// than unreachable, because the viewer cannot tell the remote did anything.
//
// Wrapping FocusHighlight around an already-focusable InkWell (or any other
// independently-focusable descendant) creates a second, hidden focus stop
// unless that descendant's own focusability is turned off. A D-pad user
// would then have to press right/down twice to clear one button, and one of
// the two stops paints no ring at all. The traversalDescendants tests below
// prove each wrapped control contributes exactly one stop.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/detail_action_row.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:player/presentation/widgets/play_button.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  // FocusHighlight's ring is gated on FocusManager.highlightMode, which
  // flutter_test otherwise derives from the default target platform
  // (android), so onShowFocusHighlight never fires and no test below could
  // ever see a ring. Forcing the traditional strategy is the documented way
  // to test focus visuals, and matches what a real keyboard or D-pad event
  // does at runtime.
  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });

  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  group('PlayButton', () {
    testWidgets('paints a visible ring when focused', (tester) async {
      await tester.pumpWidget(
        _host(PlayButton(onPressed: () {})),
      );

      final scope = FocusScope.of(tester.element(find.byType(PlayButton)));
      scope.nextFocus();
      await tester.pump();

      final decorated = tester.widget<DecoratedBox>(
        find.byKey(FocusHighlight.ringKey),
      );
      expect((decorated.decoration as BoxDecoration).border, isNotNull);
    });

    testWidgets('Enter on the focused play button starts playback',
        (tester) async {
      var presses = 0;

      await tester.pumpWidget(
        _host(PlayButton(onPressed: () => presses++)),
      );

      final scope = FocusScope.of(tester.element(find.byType(PlayButton)));
      scope.nextFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(presses, 1);
    });

    testWidgets('a disabled play button is not a focus stop', (tester) async {
      await tester.pumpWidget(
        _host(const PlayButton()),
      );

      final scope = FocusScope.of(tester.element(find.byType(PlayButton)));
      scope.nextFocus();
      await tester.pump();

      expect(scope.focusedChild, isNull);
    });

    testWidgets(
        'contributes exactly one focus stop, not two nested inside each '
        'other (regression: InkWell defaults canRequestFocus to true, which '
        'would register a second, invisible stop under FocusHighlight\'s '
        'own stop)', (tester) async {
      await tester.pumpWidget(
        _host(PlayButton(onPressed: () {})),
      );

      final scope = FocusScope.of(tester.element(find.byType(PlayButton)));

      expect(scope.traversalDescendants.length, 1);
    });
  });

  group('DetailActionRow action chip', () {
    // Only Watched and Favorite render: trailerUrl is null, showDownload is
    // false and onShowMediaInfo is null, so the row is exactly two chips
    // wide and the stop count below is unambiguous.
    Widget buildRow() => DetailActionRow(
          watched: false,
          onToggleWatched: () {},
          isFavorite: false,
          onToggleFavorite: () {},
          onDownload: () {},
          trailerUrl: null,
          showDownload: false,
        );

    testWidgets('paints a visible ring when focused', (tester) async {
      await tester.pumpWidget(_host(buildRow()));

      final scope = FocusScope.of(tester.element(find.byType(DetailActionRow)));
      scope.nextFocus();
      await tester.pump();

      final decorated = tester
          .widgetList<DecoratedBox>(find.byKey(FocusHighlight.ringKey))
          .toList();
      expect(
        decorated.any((d) => (d.decoration as BoxDecoration).border != null),
        isTrue,
      );
    });

    testWidgets('Enter on the focused chip activates its callback',
        (tester) async {
      var toggles = 0;

      await tester.pumpWidget(
        _host(
          DetailActionRow(
            watched: false,
            onToggleWatched: () => toggles++,
            isFavorite: false,
            onToggleFavorite: () {},
            onDownload: () {},
            trailerUrl: null,
            showDownload: false,
          ),
        ),
      );

      final scope = FocusScope.of(tester.element(find.byType(DetailActionRow)));
      scope.nextFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(toggles, 1);
    });

    testWidgets(
        'each chip contributes exactly one focus stop, not two nested '
        'inside each other (regression: InkWell defaults canRequestFocus to '
        'true, which would double the stop count below)', (tester) async {
      await tester.pumpWidget(_host(buildRow()));

      final scope = FocusScope.of(tester.element(find.byType(DetailActionRow)));

      // Two visible chips (Watched, Favorite); one stop apiece.
      expect(scope.traversalDescendants.length, 2);
    });
  });
}
