import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/collection.dart';
import 'package:player/presentation/screens/all_servers/all_servers_collections_screen.dart';
import 'package:player/presentation/screens/detail/detail_links.dart';
import 'package:player/presentation/widgets/collection_card.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../domain/merged/fake_merged_source.dart';
import '../../../test_utils/toast_harness.dart';

Future<List<String>> pump(
    WidgetTester tester, List<MediaSource> sources) async {
  final pushed = <String>[];
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => const AllServersCollectionsScreen()),
    GoRoute(
      path: '/s/:id/:kind/:item',
      builder: (_, s) {
        pushed.add(s.uri.toString());
        return const SizedBox();
      },
    ),
  ]);
  await tester.binding.setSurfaceSize(const Size(1280, 1800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      allServersSourcesProvider.overrideWithValue(sources),
      sourcesProvider.overrideWithValue([for (final s in sources) s.source]),
      allServersNeedSignInProvider.overrideWithValue(const []),
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child: MaterialApp.router(routerConfig: router, builder: toastLayerBuilder),
  ));
  await tester.pumpAndSettle();
  return pushed;
}

FakeMergedSource serverWith(String id) {
  final s = fakeServer(id);
  return FakeMergedSource(s, cols: [
    SourceCollection(
        sourceId: s.id, id: 'c1', name: 'Invented set $id', itemCount: 3),
  ]);
}

void main() {
  testWidgets('lists each server\'s collections captioned by server',
      (t) async {
    await pump(t, [serverWith('a'), serverWith('b')]);
    expect(find.byType(CollectionCard), findsNWidgets(2));
    expect(find.text('Server a'), findsOneWidget);
    expect(find.text('Server b'), findsOneWidget);
  });

  testWidgets('tapping a card opens that server\'s collection', (t) async {
    final a = serverWith('a'), b = serverWith('b');
    final pushed = await pump(t, [a, b]);
    await t.tap(find.byType(CollectionCard).first);
    await t.pumpAndSettle();
    expect(pushed.last, collectionLocation(a.id, 'c1'));
  });
}
