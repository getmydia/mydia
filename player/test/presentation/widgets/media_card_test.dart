// MediaCard must satisfy the shared poster depth contract (plan R7, R11).
// The contract itself lives in test_utils/poster_contract.dart so every poster
// surface asserts the same thing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/media_card.dart';
import 'package:player/presentation/widgets/progress_overlay.dart';

import '../../test_utils/poster_contract.dart';

// Tall enough for the 195px poster plus its gap and a two-line title, short
// enough that the card's center still lands on the poster. Without this the
// Column stretches to the full viewport and the center falls in empty space.
const _cardHost = Size(130, 260);

void main() {
  runPosterDepthContract(
    description: 'MediaCard',
    build: () => const MediaCard(title: 'Movie'),
    size: _cardHost,
  );

  group('MediaCard behavior', () {
    testWidgets('renders the progress overlay when progress is set',
        (tester) async {
      await tester.pumpWidget(
        posterHost(
          const MediaCard(title: 'Movie', progressPercentage: 42),
          size: _cardHost,
        ),
      );

      expect(find.byType(ProgressOverlay), findsOneWidget);
    });

    testWidgets('tap fires onTap', (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        posterHost(
          MediaCard(title: 'Movie', onTap: () => tapped = true),
          size: _cardHost,
        ),
      );
      await tester.tap(find.byType(MediaCard));

      expect(tapped, isTrue);
    });
  });
}
