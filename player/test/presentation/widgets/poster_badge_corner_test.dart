import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/poster_badge_corner.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          SizedBox(width: 200, height: 300, child: Stack(children: [child]))
        ]),
      ),
    );

void main() {
  group('PosterBadgeCorner', () {
    testWidgets('lays its children out left to right in the order given',
        (tester) async {
      await tester.pumpWidget(
        _host(const PosterBadgeCorner(
          children: [Text('first'), Text('second')],
        )),
      );

      final firstX = tester.getTopLeft(find.text('first')).dx;
      final secondX = tester.getTopLeft(find.text('second')).dx;

      expect(firstX, lessThan(secondX));
    });

    testWidgets('renders nothing when given no children', (tester) async {
      await tester.pumpWidget(
        _host(const PosterBadgeCorner(children: [])),
      );

      expect(find.byType(Row), findsNothing);
    });

    testWidgets('drops empty children so spacing does not accumulate',
        (tester) async {
      await tester.pumpWidget(
        _host(const PosterBadgeCorner(
          children: [SizedBox.shrink(), Text('only')],
        )),
      );

      expect(find.text('only'), findsOneWidget);
    });

    testWidgets('sits in the top-right of its stack', (tester) async {
      await tester.pumpWidget(
        _host(const PosterBadgeCorner(children: [Text('badge')])),
      );

      final badge = tester.getTopRight(find.text('badge'));
      expect(badge.dx, closeTo(200 - 8, 1));
      expect(tester.getTopLeft(find.text('badge')).dy, closeTo(8, 1));
    });
  });
}
