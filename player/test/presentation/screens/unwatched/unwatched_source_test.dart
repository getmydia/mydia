import 'package:flutter/material.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/unwatched/unwatched_screen.dart';
import 'package:player/presentation/widgets/browse_grid.dart';
import 'package:player/presentation/widgets/media_poster.dart';

import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';
import '../sources/listing_harness.dart';

void main() {
  testWidgets('lists the source unwatched titles and opens one on that source',
      (tester) async {
    final a = FakeCapableSource()
      ..unwatchedPages = [
        Page(items: [fakeMovie(1)])
      ];
    final pushed = await pumpListing(
      tester,
      const UnwatchedScreen(sourceId: fakeSourceId),
      sources: [a],
    );

    expect(find.text('Unwatched'), findsOneWidget);
    expect(find.byType(BrowseGrid), findsOneWidget);
    expect(find.byType(MediaPoster), findsOneWidget);

    await tester.tap(find.text('Invented Film 1'));
    await tester.pumpAndSettle();
    expect(pushed.last, '/s/acc1:owner:aa11/movie/m1');
  });

  testWidgets('shows the listing of the source it is scoped to',
      (tester) async {
    final a = FakeCapableSource()
      ..unwatchedPages = [
        Page(items: [fakeMovie(1)])
      ];
    final b = FakeCapableSource(id: otherSourceId)
      ..unwatchedPages = [
        Page(items: [listingMovie(otherSourceId, 'b1', 'Other Unseen Film')])
      ];
    await pumpListing(
      tester,
      const UnwatchedScreen(sourceId: otherSourceId),
      sources: [a, b],
    );

    expect(find.text('Other Unseen Film'), findsOneWidget);
    expect(find.text('Invented Film 1'), findsNothing);
  });

  testWidgets('loads the next page as the grid nears its end', (tester) async {
    final a = FakeCapableSource()
      ..unwatchedPages = [
        Page(
          items: [for (var n = 1; n <= 40; n++) fakeMovie(n)],
          nextCursor: const Cursor('1'),
        ),
        Page(items: [fakeMovie(41)]),
      ];
    await pumpListing(
      tester,
      const UnwatchedScreen(sourceId: fakeSourceId),
      sources: [a],
    );
    expect(a.calls, ['unwatched(null)']);

    await tester.drag(find.byType(GridView), const Offset(0, -20000));
    await tester.pumpAndSettle();

    expect(a.calls, contains('unwatched(1)'));
  });

  testWidgets('keeps its empty state', (tester) async {
    await pumpListing(
      tester,
      const UnwatchedScreen(sourceId: fakeSourceId),
      sources: [FakeCapableSource()],
    );

    expect(find.text('All caught up!'), findsOneWidget);
  });

  testWidgets('draws an unwatched count on a show', (tester) async {
    final a = FakeCapableSource()
      ..unwatchedPages = [
        Page(items: [
          listingShow(fakeSourceId, 's9', 'Unseen Show', unwatched: 6)
        ])
      ];
    await pumpListing(
      tester,
      const UnwatchedScreen(sourceId: fakeSourceId),
      sources: [a],
    );

    expect(find.text('6'), findsOneWidget);
  });
}
