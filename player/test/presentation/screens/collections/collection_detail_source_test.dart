import 'package:flutter/material.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/collection_sync_providers.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/domain/models/download_option.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/collections/collection_detail_screen.dart';
import 'package:player/presentation/widgets/media_poster.dart';
import 'package:player/presentation/widgets/quality_download_dialog.dart';

import '../detail/download_fakes.dart';
import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';
import '../sources/listing_harness.dart';

void main() {
  testWidgets('lists the collection items and opens one on that source',
      (tester) async {
    final a = FakeCapableSource()
      ..collectionItemPages = [
        Page(items: [fakeMovie(1), fakeMovie(2)])
      ];
    final pushed = await pumpListing(
      tester,
      const CollectionDetailScreen(sourceId: fakeSourceId, collectionId: 'c1'),
      sources: [a],
    );

    expect(find.byType(MediaPoster), findsNWidgets(2));
    expect(a.calls, ['collectionItems(c1, null)']);

    await tester.tap(find.text('Invented Film 1'));
    await tester.pumpAndSettle();
    expect(pushed.last, '/s/acc1:owner:aa11/movie/m1');
  });

  testWidgets('shows the collection of the source it is scoped to',
      (tester) async {
    final a = FakeCapableSource()
      ..collectionItemPages = [
        Page(items: [fakeMovie(1)])
      ];
    final b = FakeCapableSource(id: otherSourceId)
      ..collectionItemPages = [
        Page(items: [listingMovie(otherSourceId, 'b1', 'Other Saga Film')])
      ];
    await pumpListing(
      tester,
      const CollectionDetailScreen(sourceId: otherSourceId, collectionId: 'c1'),
      sources: [a, b],
    );

    expect(find.text('Other Saga Film'), findsOneWidget);
    expect(find.text('Invented Film 1'), findsNothing);
    expect(a.calls, isEmpty);
  });

  testWidgets('loads the next page as the grid nears its end', (tester) async {
    final a = FakeCapableSource()
      ..collectionItemPages = [
        Page(
          items: [for (var n = 1; n <= 40; n++) fakeMovie(n)],
          nextCursor: const Cursor('1'),
        ),
        Page(items: [fakeMovie(41)]),
      ];
    await pumpListing(
      tester,
      const CollectionDetailScreen(sourceId: fakeSourceId, collectionId: 'c1'),
      sources: [a],
    );

    await tester.drag(find.byType(GridView), const Offset(0, -20000));
    await tester.pumpAndSettle();

    expect(a.calls, contains('collectionItems(c1, 1)'));
  });

  testWidgets('keeps its empty state', (tester) async {
    await pumpListing(
      tester,
      const CollectionDetailScreen(sourceId: fakeSourceId, collectionId: 'c1'),
      sources: [FakeCapableSource()],
    );

    expect(find.text('Collection is empty'), findsOneWidget);
  });

  testWidgets('the download button asks which option when there are several',
      (tester) async {
    final a = FakeCapableSource()
      ..collectionItemPages = [
        Page(items: [fakeMovie(1)])
      ]
      ..downloadOptionsResult = const [
        DownloadOption(
            resolution: 'original', label: 'Original', estimatedSize: 1),
        DownloadOption(resolution: '720p', label: '720p', estimatedSize: 1),
      ];
    await pumpListing(
      tester,
      const CollectionDetailScreen(sourceId: fakeSourceId, collectionId: 'c1'),
      sources: [a],
      overrides: [
        downloadManagerProvider
            .overrideWith((ref) async => EmptyDownloadService()),
        isCollectionSyncedProvider('c1').overrideWith((ref) async => false),
      ],
    );

    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pumpAndSettle();

    expect(find.byType(QualityDownloadDialog), findsOneWidget);
    expect(a.calls, contains('downloadOptions(m1)'));
  });
}
