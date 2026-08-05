// MediaPoster must satisfy the shared poster depth contract (plan R7, R11).
// The contract itself lives in test_utils/poster_contract.dart so every poster
// surface asserts the same thing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/media_poster.dart';

import '../../test_utils/hover_affordance.dart';
import '../../test_utils/poster_contract.dart';

const _posterHost = Size(140, 230);

void main() {
  runPosterDepthContract(
    description: 'MediaPoster',
    build: () => const MediaPoster(title: 'Show'),
    size: _posterHost,
  );

  group('MediaPoster behavior', () {
    testWidgets(
        'offers no play affordance at rest or on hover, because tapping a '
        'poster opens the title rather than playing it', (tester) async {
      await tester.pumpWidget(
        posterHost(const MediaPoster(title: 'Show'), size: _posterHost),
      );
      await tester.pumpAndSettle();

      expect(findPlayGlyph(), findsNothing);

      await hoverOver(tester, find.byType(MediaPoster));

      expect(findPlayGlyph(), findsNothing);
    });

    testWidgets(
        'the click cursor covers the title, which shares the poster\'s tap '
        'target', (tester) async {
      await tester.pumpWidget(
        posterHost(
          MediaPoster(title: 'Show', onTap: () {}),
          size: _posterHost,
        ),
      );
      await tester.pumpAndSettle();

      // The region carrying the cursor has to enclose the title label, since
      // the GestureDetector beneath it navigates from there too.
      final region = find
          .descendant(
            of: find.byType(MediaPoster),
            matching: find.byType(MouseRegion),
          )
          .first;

      expect(
          tester.widget<MouseRegion>(region).cursor, SystemMouseCursors.click);
      expect(
        tester.getRect(region).contains(tester.getCenter(find.text('Show'))),
        isTrue,
      );
    });

    testWidgets('an inert poster defers its cursor', (tester) async {
      await tester.pumpWidget(
        posterHost(const MediaPoster(title: 'Show'), size: _posterHost),
      );
      await tester.pumpAndSettle();

      expect(
        hoverCursor(tester, of: find.byType(MediaPoster)),
        MouseCursor.defer,
      );
    });

    testWidgets('tap fires onTap', (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        posterHost(
          MediaPoster(title: 'Show', onTap: () => tapped = true),
          size: _posterHost,
        ),
      );
      await tester.tap(find.byType(MediaPoster));

      expect(tapped, isTrue);
    });
  });
}
