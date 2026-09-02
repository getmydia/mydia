// Rail skeleton parity.
//
// `ContentRail` and `ShimmerRail` are separate widgets that must lay out
// identically, so the home screen does not resize when data replaces the
// placeholder. They held independent copies of their geometry until
// 2026-09-01 and every number had drifted. Both now read `RailMetrics`; this
// suite is what keeps them reading the same one.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/recently_added_item.dart';
import 'package:player/presentation/widgets/content_rail.dart';
import 'package:player/presentation/widgets/poster_frame.dart';
import 'package:player/presentation/widgets/shimmer_card.dart';

/// The title the real rail under test carries. Also the finder for its header
/// text, which is why it is a constant rather than a literal in two places.
const railParityTitle = 'Recently Added';

/// One viewport per `Breakpoints` tier.
///
/// 1000x800 is load-bearing rather than a third sample for its own sake.
/// `Breakpoints.isDesktop` flips at 900 and the card size at 1200, so 1000 is
/// the only width where the header is on its wide padding while the cards are
/// still tablet-sized. A `RailMetrics` that collapsed the two thresholds would
/// pass at 599 and 1400 and fail only here.
const railParityViewports = <Size>[
  Size(599, 800),
  Size(1000, 800),
  Size(1400, 900),
];

List<RecentlyAddedItem> _items(int n) => List<RecentlyAddedItem>.generate(
      n,
      (i) => RecentlyAddedItem(
        id: 'parity-$i',
        type: 'movie',
        title: 'The Lantern Wastes $i',
        year: 2019 + i,
      ),
    );

Future<void> _pump(WidgetTester tester, Widget rail, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [rail],
          ),
        ),
      ),
    ),
  );

  // Never pumpAndSettle here. `ShimmerRail` animates forever, so settling
  // times out. Two fixed pumps clear the rail's 220ms AnimatedSize.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _pumpReal(WidgetTester tester, Size size) => _pump(
      tester,
      ContentRail(title: railParityTitle, items: _items(8)),
      size,
    );

Future<void> _pumpSkeleton(WidgetTester tester, Size size) =>
    _pump(tester, const ShimmerRail(), size);

/// [target]'s rect expressed relative to [ancestor]'s top-left, so the two
/// rails can be compared without depending on where each was placed.
Rect _relativeRect(WidgetTester tester, Finder ancestor, Finder target) =>
    tester.getRect(target).shift(-tester.getTopLeft(ancestor));

/// Compares two rects component by component.
///
/// Tolerant to half a pixel rather than exact, because the poster's `top`
/// depends on the header text's measured line height and font metrics round.
/// The smallest genuine drift this suite must catch is 4px, so half a pixel
/// leaves the assertions sharp.
void _expectRect(Rect actual, Rect expected) {
  expect(actual.left, moreOrLessEquals(expected.left, epsilon: 0.5));
  expect(actual.top, moreOrLessEquals(expected.top, epsilon: 0.5));
  expect(actual.width, moreOrLessEquals(expected.width, epsilon: 0.5));
  expect(actual.height, moreOrLessEquals(expected.height, epsilon: 0.5));
}

/// Asserts that `ShimmerRail` and `ContentRail` lay out identically at every
/// breakpoint.
void runRailSkeletonParity() {
  group('rail skeleton parity', () {
    for (final size in railParityViewports) {
      final label = '${size.width.toInt()}x${size.height.toInt()}';

      testWidgets('$label: both rails are the same height', (tester) async {
        await _pumpReal(tester, size);
        final real = tester.getSize(find.byType(ContentRail)).height;

        await _pumpSkeleton(tester, size);
        final skeleton = tester.getSize(find.byType(ShimmerRail)).height;

        expect(skeleton, moreOrLessEquals(real, epsilon: 0.5));
      });

      testWidgets('$label: the first poster occupies the same rect',
          (tester) async {
        await _pumpReal(tester, size);
        final real = _relativeRect(
          tester,
          find.byType(ContentRail),
          find.byType(PosterFrame).at(0),
        );

        await _pumpSkeleton(tester, size);
        final skeleton = _relativeRect(
          tester,
          find.byType(ShimmerRail),
          find.byKey(ShimmerRail.posterKeyAt(0)),
        );

        _expectRect(skeleton, real);
      });

      testWidgets('$label: the second poster occupies the same rect',
          (tester) async {
        // Card 1 alone cannot see a wrong `cardSpacing`. Card 2 can.
        await _pumpReal(tester, size);
        final real = _relativeRect(
          tester,
          find.byType(ContentRail),
          find.byType(PosterFrame).at(1),
        );

        await _pumpSkeleton(tester, size);
        final skeleton = _relativeRect(
          tester,
          find.byType(ShimmerRail),
          find.byKey(ShimmerRail.posterKeyAt(1)),
        );

        _expectRect(skeleton, real);
      });

      testWidgets('$label: the header sits on the same line', (tester) async {
        await _pumpReal(tester, size);
        final real = _relativeRect(
          tester,
          find.byType(ContentRail),
          find.text(railParityTitle),
        );

        await _pumpSkeleton(tester, size);
        final skeleton = _relativeRect(
          tester,
          find.byType(ShimmerRail),
          find.byKey(ShimmerRail.headerKey),
        );

        // Top and height only. The real header is as wide as its title text
        // and the placeholder bar is a fixed 150, which is deliberate.
        expect(skeleton.top, moreOrLessEquals(real.top, epsilon: 0.5));
        expect(skeleton.height, moreOrLessEquals(real.height, epsilon: 0.5));
      });
    }
  });
}
