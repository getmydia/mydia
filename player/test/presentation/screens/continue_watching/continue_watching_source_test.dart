import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/continue_watching/continue_watching_screen.dart';
import 'package:player/presentation/widgets/browse_grid.dart';
import 'package:player/presentation/widgets/media_poster.dart';
import 'package:player/presentation/widgets/progress_overlay.dart';

import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';
import '../sources/listing_harness.dart';

ItemSummary _inProgress(int n) => fakeMovie(n, progress: 1200);

Future<PushedLocations> _pump(
  WidgetTester tester,
  FakeCapableSource source, {
  List<FakeCapableSource> others = const [],
}) =>
    pumpListing(
      tester,
      ContinueWatchingScreen(sourceId: source.id),
      sources: [source, ...others],
    );

Future<void> _removeFirstCard(WidgetTester tester) async {
  await tester.longPress(find.byType(MediaPoster).first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Remove from Continue Watching'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists what is in progress and opens an item on that source',
      (tester) async {
    final a = FakeCapableSource()
      ..continueWatchingResult = [_inProgress(1), _inProgress(2)];
    final pushed = await _pump(tester, a);

    expect(find.text('Continue Watching'), findsOneWidget);
    expect(find.byType(BrowseGrid), findsOneWidget);
    expect(find.byType(MediaPoster), findsNWidgets(2));

    await tester.tap(find.text('Invented Film 2'));
    await tester.pumpAndSettle();
    expect(pushed.last, '/s/acc1:owner:aa11/movie/m2');
  });

  testWidgets('shows the listing of the source it is scoped to',
      (tester) async {
    final a = FakeCapableSource()..continueWatchingResult = [_inProgress(1)];
    final b = FakeCapableSource(id: otherSourceId)
      ..continueWatchingResult = [
        listingMovie(otherSourceId, 'b1', 'Other Resume Film'),
      ];
    await _pump(tester, b, others: [a]);

    expect(find.text('Other Resume Film'), findsOneWidget);
    expect(find.text('Invented Film 1'), findsNothing);
    expect(a.calls, isNot(contains('continueWatching()')));
  });

  testWidgets('renders the empty state when nothing is in progress',
      (tester) async {
    await _pump(tester, FakeCapableSource());

    expect(find.text('Nothing in progress.'), findsOneWidget);
  });

  testWidgets('draws a progress bar for a part-played item', (tester) async {
    await _pump(
      tester,
      FakeCapableSource()..continueWatchingResult = [_inProgress(1)],
    );

    expect(find.byType(ProgressOverlay), findsOneWidget);
  });

  testWidgets('draws no bar for an item already marked watched',
      (tester) async {
    await _pump(
      tester,
      FakeCapableSource()
        ..continueWatchingResult = [
          fakeMovie(1, watched: true, progress: 3600)
        ],
    );

    expect(find.byType(ProgressOverlay), findsNothing);
  });

  testWidgets('removing a card calls the source and takes it off the grid',
      (tester) async {
    final a = FakeCapableSource()
      ..continueWatchingResult = [_inProgress(1), _inProgress(2)];
    await _pump(tester, a);

    await _removeFirstCard(tester);

    expect(a.removed.map((r) => r.externalId), ['m1']);
    expect(find.text('Invented Film 1'), findsNothing);
    expect(find.text('Invented Film 2'), findsOneWidget);
  });

  testWidgets('a failed removal puts the card back', (tester) async {
    final a = FakeCapableSource()
      ..continueWatchingResult = [_inProgress(1), _inProgress(2)]
      ..removeError = StateError('refused');
    await _pump(tester, a);

    await _removeFirstCard(tester);

    expect(a.removed.map((r) => r.externalId), ['m1']);
    expect(find.text('Invented Film 1'), findsOneWidget);
    expect(find.text('Invented Film 2'), findsOneWidget);
    expect(
        find.text('Could not remove from Continue Watching'), findsOneWidget);
  });

  testWidgets('a source that cannot dismiss an entry offers no menu',
      (tester) async {
    final a = FakeCapableSource()
      ..continueWatchingResult = [_inProgress(1)]
      ..removable = false;
    await _pump(tester, a);

    await tester.longPress(find.byType(MediaPoster).first);
    await tester.pumpAndSettle();

    expect(find.text('Remove from Continue Watching'), findsNothing);
  });
}
