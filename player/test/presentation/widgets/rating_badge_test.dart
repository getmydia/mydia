import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/presentation/widgets/rating_badge.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('rounds the score to one decimal place', (tester) async {
    await tester.pumpWidget(_host(const RatingBadge(rating: 7.75)));

    expect(find.text('7.8'), findsOneWidget);
  });

  testWidgets('keeps a trailing decimal on a whole score', (tester) async {
    // A whole-valued score must still show its decimal place, so the chip
    // reads "8.0" rather than "8".
    await tester.pumpWidget(_host(const RatingBadge(rating: 8)));

    expect(find.text('8.0'), findsOneWidget);
  });

  testWidgets('carries a star in the app accent, matching the detail screen',
      (tester) async {
    await tester.pumpWidget(_host(const RatingBadge(rating: 6.1)));

    final icon = tester.widget<Icon>(find.byIcon(Icons.star_rounded));
    expect(icon.color, AppColors.primary);
  });

  testWidgets('sits on a dark scrim rather than a palette surface',
      (tester) async {
    // The chip is drawn straight onto poster artwork, so its legibility comes
    // from the scrim. A palette surface colour would wash out over a bright
    // poster.
    await tester.pumpWidget(_host(const RatingBadge(rating: 6.1)));

    final container = tester.widget<Container>(
      find.descendant(
        of: find.byType(RatingBadge),
        matching: find.byType(Container),
      ),
    );
    final decoration = container.decoration as BoxDecoration;
    expect(decoration.color, Colors.black.withValues(alpha: 0.4));
  });
}
