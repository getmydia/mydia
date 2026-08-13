// MediaPoster must satisfy the shared poster depth contract (plan R7, R11).
// The contract itself lives in test_utils/poster_contract.dart so every poster
// surface asserts the same thing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/watch_status.dart';
import 'package:player/presentation/widgets/media_poster.dart';
import 'package:player/presentation/widgets/rating_badge.dart';
import 'package:player/presentation/widgets/watch_indicator.dart';

import '../../test_utils/hover_affordance.dart';
import '../../test_utils/poster_contract.dart';
import '../../test_utils/watch_indicator_contract.dart';

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

    testWidgets('renders the rating chip when a title has one', (tester) async {
      await tester.pumpWidget(
        posterHost(
          const MediaPoster(title: 'Show', rating: 7.8),
          size: _posterHost,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RatingBadge), findsOneWidget);
      expect(find.text('7.8'), findsOneWidget);
    });

    testWidgets('renders no chip when a title has no rating', (tester) async {
      await tester.pumpWidget(
        posterHost(const MediaPoster(title: 'Show'), size: _posterHost),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RatingBadge), findsNothing);
    });

    testWidgets('renders no chip for 0.0, which TMDB uses for "no votes yet"',
        (tester) async {
      // The server passes vote_average through unchanged, so an unvoted title
      // is indistinguishable from an unrated one and both must show nothing.
      await tester.pumpWidget(
        posterHost(
          const MediaPoster(title: 'Show', rating: 0),
          size: _posterHost,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(RatingBadge), findsNothing);
    });

    testWidgets('the chip clears the favorite heart', (tester) async {
      // The heart holds top-right and the chip holds top-left, so a favorite
      // with a rating shows both without either covering the other.
      await tester.pumpWidget(
        posterHost(
          const MediaPoster(title: 'Show', rating: 7.8, isFavorite: true),
          size: _posterHost,
        ),
      );
      await tester.pumpAndSettle();

      final chip = tester.getRect(find.byType(RatingBadge));
      final heart = tester.getRect(find.byIcon(Icons.favorite));

      expect(chip.right, lessThan(heart.left));
    });
  });

  runWatchIndicatorContract(
    description: 'MediaPoster',
    build: (status, legacyProgress) => MediaPoster(
      title: 'Show',
      watchStatus: status,
      progressPercentage: legacyProgress,
    ),
    size: _posterHost,
  );

  group('MediaPoster watch indicators', () {
    testWidgets('keeps the favourite heart alongside the indicator',
        (tester) async {
      await tester.pumpWidget(
        posterHost(
          const MediaPoster(
            title: 'Show',
            isFavorite: true,
            watchStatus: WatchStatus(watched: false),
          ),
          size: _posterHost,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(WatchIndicator.dotKey), findsOneWidget);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
    });
  });
}
