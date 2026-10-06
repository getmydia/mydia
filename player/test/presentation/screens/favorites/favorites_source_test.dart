import 'package:flutter/material.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/favorites/favorites_screen.dart';
import 'package:player/presentation/widgets/browse_grid.dart';
import 'package:player/presentation/widgets/media_poster.dart';

import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';
import '../sources/listing_harness.dart';

void main() {
  testWidgets('lists the source favorites and opens an item on that source',
      (tester) async {
    final a = FakeCapableSource()
      ..favoritePages = [
        Page(items: [fakeMovie(1), fakeMovie(2)])
      ];
    final pushed = await pumpListing(
      tester,
      const FavoritesScreen(sourceId: fakeSourceId),
      sources: [a],
    );

    expect(find.text('Favorites'), findsOneWidget);
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    expect(find.byType(BrowseGrid), findsOneWidget);
    expect(find.byType(MediaPoster), findsNWidgets(2));
    expect(find.text('Invented Film 1'), findsOneWidget);

    await tester.tap(find.text('Invented Film 1'));
    await tester.pumpAndSettle();
    expect(pushed.last, '/s/acc1:owner:aa11/movie/m1');
  });

  testWidgets('shows the listing of the source it is scoped to',
      (tester) async {
    final a = FakeCapableSource()
      ..favoritePages = [
        Page(items: [fakeMovie(1)])
      ];
    final b = FakeCapableSource(id: otherSourceId)
      ..favoritePages = [
        Page(items: [listingMovie(otherSourceId, 'b1', 'Other Shelf Film')])
      ];
    await pumpListing(
      tester,
      const FavoritesScreen(sourceId: otherSourceId),
      sources: [a, b],
    );

    expect(find.text('Other Shelf Film'), findsOneWidget);
    expect(find.text('Invented Film 1'), findsNothing);
    expect(a.calls, isNot(contains('favorites(null)')));
  });

  testWidgets('loads the next page as the grid nears its end', (tester) async {
    final a = FakeCapableSource()
      ..favoritePages = [
        Page(
          items: [for (var n = 1; n <= 40; n++) fakeMovie(n)],
          nextCursor: const Cursor('1'),
        ),
        Page(items: [fakeMovie(41)]),
      ];
    await pumpListing(
      tester,
      const FavoritesScreen(sourceId: fakeSourceId),
      sources: [a],
    );
    expect(a.calls, ['favorites(null)']);

    await tester.drag(find.byType(GridView), const Offset(0, -20000));
    await tester.pumpAndSettle();

    expect(a.calls, contains('favorites(1)'));
  });

  testWidgets('keeps its empty state', (tester) async {
    await pumpListing(
      tester,
      const FavoritesScreen(sourceId: fakeSourceId),
      sources: [FakeCapableSource()],
    );

    expect(find.text('No favorites yet'), findsOneWidget);
  });
}
