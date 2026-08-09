// MediaCard must satisfy the shared poster depth contract (plan R7, R11).
// The contract itself lives in test_utils/poster_contract.dart so every poster
// surface asserts the same thing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/media_card.dart';
import 'package:player/presentation/widgets/progress_overlay.dart';

import '../../test_utils/hover_affordance.dart';
import '../../test_utils/poster_contract.dart';

// Tall enough for the 195px poster plus its gap and a two-line title, short
// enough that the card's center still lands on the poster. Without this the
// Column stretches to the full viewport and the center falls in empty space.
const _cardHost = Size(130, 260);

void main() {
  runPosterDepthContract(
    description: 'MediaCard',
    build: () => const MediaCard(title: 'Movie', action: MediaCardAction.open),
    size: _cardHost,
  );

  group('MediaCard behavior', () {
    testWidgets('renders the progress overlay when progress is set',
        (tester) async {
      await tester.pumpWidget(
        posterHost(
          const MediaCard(
            title: 'Movie',
            progressPercentage: 42,
            action: MediaCardAction.open,
          ),
          size: _cardHost,
        ),
      );

      expect(find.byType(ProgressOverlay), findsOneWidget);
    });

    testWidgets(
        'an open card offers no play affordance at rest or on hover, because '
        'tapping it opens the title rather than playing it', (tester) async {
      await tester.pumpWidget(
        posterHost(
          const MediaCard(title: 'Movie', action: MediaCardAction.open),
          size: _cardHost,
        ),
      );
      await tester.pumpAndSettle();

      expect(findPlayGlyph(), findsNothing);

      await hoverOver(tester, find.byType(MediaCard));

      expect(findPlayGlyph(), findsNothing);
    });

    testWidgets(
        'a play card shows its badge at rest, so a touch user can see the tap '
        'will start playback', (tester) async {
      await tester.pumpWidget(
        posterHost(
          const MediaCard(title: 'Movie', action: MediaCardAction.play),
          size: _cardHost,
        ),
      );
      await tester.pumpAndSettle();

      // At rest, with no pointer anywhere near it: this is the whole point of
      // the badge, since hover never fires on a phone.
      expect(find.byKey(MediaCard.playBadgeKey), findsOneWidget);
      expect(findPlayGlyph(), findsOneWidget);
    });

    testWidgets('the play badge clears the progress bar', (tester) async {
      await tester.pumpWidget(
        posterHost(
          const MediaCard(
            title: 'Movie',
            progressPercentage: 42,
            action: MediaCardAction.play,
          ),
          size: _cardHost,
        ),
      );
      await tester.pumpAndSettle();

      final badge = tester.getRect(find.byKey(MediaCard.playBadgeKey));
      final bar = tester.getRect(find.byType(ProgressOverlay));

      expect(badge.bottom, lessThanOrEqualTo(bar.top));
    });

    testWidgets('a tappable card offers a click cursor, an inert one defers',
        (tester) async {
      await tester.pumpWidget(
        posterHost(
          MediaCard(
            title: 'Movie',
            action: MediaCardAction.open,
            onTap: () {},
          ),
          size: _cardHost,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        hoverCursor(tester, of: find.byType(MediaCard)),
        SystemMouseCursors.click,
      );

      await tester.pumpWidget(
        posterHost(
          const MediaCard(title: 'Movie', action: MediaCardAction.open),
          size: _cardHost,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        hoverCursor(tester, of: find.byType(MediaCard)),
        MouseCursor.defer,
      );
    });

    testWidgets('tap fires onTap', (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        posterHost(
          MediaCard(
            title: 'Movie',
            action: MediaCardAction.open,
            onTap: () => tapped = true,
          ),
          size: _cardHost,
        ),
      );
      await tester.tap(find.byType(MediaCard));

      expect(tapped, isTrue);
    });
  });

  group('MediaCard secondary gestures', () {
    testWidgets('long press hands back a context inside the card',
        (tester) async {
      BuildContext? received;

      await tester.pumpWidget(
        posterHost(
          MediaCard(
            title: 'Movie',
            action: MediaCardAction.play,
            onContextMenu: (context) => received = context,
          ),
          size: _cardHost,
        ),
      );
      await tester.longPress(find.byType(MediaCard));
      await tester.pump();

      expect(received, isNotNull);
      // The menu anchors to the card's own render box, so the context handed
      // back has to resolve to one.
      expect(received?.findRenderObject(), isA<RenderBox>());
    });

    testWidgets('a card with no menu ignores a long press', (tester) async {
      await tester.pumpWidget(
        posterHost(
          const MediaCard(title: 'Movie', action: MediaCardAction.open),
          size: _cardHost,
        ),
      );

      await tester.longPress(find.byType(MediaCard));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
