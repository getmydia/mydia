import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/movie_watched_controls.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  group('MovieWatchedButton', () {
    testWidgets('renders an outline icon when unwatched', (tester) async {
      await _pump(
        tester,
        MovieWatchedButton(watched: false, onPressed: () {}),
      );

      expect(
        find.byIcon(Icons.check_circle_outline_rounded),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.check_circle_rounded), findsNothing);
    });

    testWidgets('renders a filled icon when watched', (tester) async {
      await _pump(
        tester,
        MovieWatchedButton(watched: true, onPressed: () {}),
      );

      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(
        find.byIcon(Icons.check_circle_outline_rounded),
        findsNothing,
      );
    });

    testWidgets('offers the opposite action as its tooltip', (tester) async {
      await _pump(
        tester,
        MovieWatchedButton(watched: false, onPressed: () {}),
      );

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'Mark watched');
    });

    testWidgets('a watched button offers to unmark', (tester) async {
      await _pump(
        tester,
        MovieWatchedButton(watched: true, onPressed: () {}),
      );

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'Mark unwatched');
    });

    testWidgets('a tap fires onPressed exactly once', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        MovieWatchedButton(watched: false, onPressed: () => taps++),
      );

      await tester.tap(find.byType(MovieWatchedButton));
      await tester.pump();

      expect(taps, 1);
    });
  });

  group('MovieWatchedLine', () {
    testWidgets('reads plainly when there is no date', (tester) async {
      await _pump(tester, const MovieWatchedLine());

      expect(find.text('Watched'), findsOneWidget);
    });

    testWidgets('appends the date when there is one', (tester) async {
      await _pump(tester, const MovieWatchedLine(dateLabel: 'Aug 2'));

      expect(find.text('Watched · Aug 2'), findsOneWidget);
      expect(find.text('Watched'), findsNothing);
    });

    testWidgets('carries a check icon', (tester) async {
      await _pump(tester, const MovieWatchedLine());

      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    });
  });
}
