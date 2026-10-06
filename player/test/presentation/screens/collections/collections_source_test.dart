import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/collection.dart';
import 'package:player/presentation/screens/collections/collections_screen.dart';

import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';
import '../sources/listing_harness.dart';

SourceCollection _collection(
  String id,
  String name, {
  SourceId sourceId = fakeSourceId,
}) =>
    SourceCollection(sourceId: sourceId, id: id, name: name, itemCount: 3);

void main() {
  testWidgets('lists the source collections and opens one on that source',
      (tester) async {
    final a = FakeCapableSource()
      ..collectionsResult = [_collection('c1', 'Invented Saga')];
    final pushed = await pumpListing(
      tester,
      const CollectionsScreen(sourceId: fakeSourceId),
      sources: [a],
    );

    expect(find.text('Collections'), findsOneWidget);
    expect(find.byIcon(Icons.collections_bookmark_rounded), findsOneWidget);
    expect(find.text('Invented Saga'), findsOneWidget);

    await tester.tap(find.text('Invented Saga'));
    await tester.pumpAndSettle();
    expect(pushed.last, '/s/acc1:owner:aa11/collection/c1');
  });

  testWidgets('keeps its own card geometry, not the shared poster grid',
      (tester) async {
    final a = FakeCapableSource()
      ..collectionsResult = [_collection('c1', 'Invented Saga')];
    await pumpListing(
      tester,
      const CollectionsScreen(sourceId: fakeSourceId),
      sources: [a],
    );

    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.childAspectRatio, 0.85);
  });

  testWidgets('shows the collections of the source it is scoped to',
      (tester) async {
    final a = FakeCapableSource()
      ..collectionsResult = [_collection('c1', 'Invented Saga')];
    final b = FakeCapableSource(id: otherSourceId)
      ..collectionsResult = [
        _collection('c9', 'Other Anthology', sourceId: otherSourceId),
      ];
    await pumpListing(
      tester,
      const CollectionsScreen(sourceId: otherSourceId),
      sources: [a, b],
    );

    expect(find.text('Other Anthology'), findsOneWidget);
    expect(find.text('Invented Saga'), findsNothing);
    expect(a.calls, isNot(contains('collections()')));
  });

  testWidgets('keeps its empty state', (tester) async {
    await pumpListing(
      tester,
      const CollectionsScreen(sourceId: fakeSourceId),
      sources: [FakeCapableSource()],
    );

    expect(find.text('No collections yet'), findsOneWidget);
    expect(
      find.text('Create collections in Mydia to organize your media'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.collections_bookmark_outlined), findsOneWidget);
  });
}
