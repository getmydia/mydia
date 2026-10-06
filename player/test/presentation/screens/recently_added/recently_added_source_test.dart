import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/recently_added/recently_added_screen.dart';
import 'package:player/presentation/widgets/browse_grid.dart';
import 'package:player/presentation/widgets/media_poster.dart';

import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';
import '../sources/listing_harness.dart';

void main() {
  testWidgets('lists what was added and opens an item on that source',
      (tester) async {
    final a = FakeCapableSource()
      ..recentlyAddedResult = [fakeMovie(1), fakeMovie(2)];
    final pushed = await pumpListing(
      tester,
      const RecentlyAddedScreen(sourceId: fakeSourceId),
      sources: [a],
    );

    expect(find.text('Recently Added'), findsOneWidget);
    expect(find.byIcon(Icons.fiber_new_rounded), findsOneWidget);
    expect(find.byType(BrowseGrid), findsOneWidget);
    expect(find.byType(MediaPoster), findsNWidgets(2));

    await tester.tap(find.text('Invented Film 2'));
    await tester.pumpAndSettle();
    expect(pushed.last, '/s/acc1:owner:aa11/movie/m2');
  });

  testWidgets('shows the listing of the source it is scoped to',
      (tester) async {
    final a = FakeCapableSource()..recentlyAddedResult = [fakeMovie(1)];
    final b = FakeCapableSource(id: otherSourceId)
      ..recentlyAddedResult = [
        listingMovie(otherSourceId, 'b1', 'Other New Film'),
      ];
    await pumpListing(
      tester,
      const RecentlyAddedScreen(sourceId: otherSourceId),
      sources: [a, b],
    );

    expect(find.text('Other New Film'), findsOneWidget);
    expect(find.text('Invented Film 1'), findsNothing);
    expect(a.calls, isNot(contains('recentlyAdded()')));
  });

  testWidgets('keeps its empty state', (tester) async {
    await pumpListing(
      tester,
      const RecentlyAddedScreen(sourceId: fakeSourceId),
      sources: [FakeCapableSource()],
    );

    expect(find.text('Nothing new'), findsOneWidget);
  });
}
