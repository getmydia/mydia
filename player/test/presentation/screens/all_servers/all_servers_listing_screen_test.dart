import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/all_servers/all_servers_cards.dart';
import 'package:player/presentation/screens/all_servers/all_servers_listing_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../domain/merged/fake_merged_source.dart';
import '../../../test_utils/toast_harness.dart';

Future<void> pump(WidgetTester tester, List<MediaSource> sources,
    {required AllServersListing listing, LibraryKind? kind}) async {
  final router = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (_, __) => AllServersListingScreen(listing: listing, kind: kind),
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
}

const shared = ExternalIds(tmdb: '1');

void main() {
  testWidgets('recently added filters by kind and dedupes', (t) async {
    final sa = fakeServer('a'), sb = fakeServer('b');
    await pump(
        t,
        [
          FakeMergedSource(sa, recent: [
            item(sa, 'm1', addedAt: DateTime.utc(2024, 1, 2), ids: shared),
            item(sa, 's1',
                kind: ItemKind.show, addedAt: DateTime.utc(2024, 1, 1)),
          ]),
          FakeMergedSource(sb, recent: [
            item(sb, 'm1', addedAt: DateTime.utc(2024, 1, 1), ids: shared),
          ]),
        ],
        listing: AllServersListing.recentlyAdded);
    expect(find.byKey(const Key('all-listing-grid')), findsOneWidget);
    expect(find.byType(AllServersPoster), findsNWidgets(2));
    await t.tap(find.byKey(const Key('all-listing-kind-movies')));
    await t.pumpAndSettle();
    expect(find.byType(AllServersPoster), findsOneWidget);
    expect(find.textContaining('+1'), findsOneWidget);
    await t.tap(find.byKey(const Key('all-listing-kind-shows')));
    await t.pumpAndSettle();
    expect(find.byType(AllServersPoster), findsOneWidget);
    expect(find.textContaining('+1'), findsNothing);
  });

  testWidgets('shows an empty message when the chosen kind has no items',
      (t) async {
    final sa = fakeServer('a');
    await pump(
        t,
        [
          FakeMergedSource(sa, recent: [
            item(sa, 'm1', addedAt: DateTime.utc(2024, 1, 2)),
          ]),
          FakeMergedSource(fakeServer('b')),
        ],
        listing: AllServersListing.recentlyAdded);
    expect(find.byKey(const Key('all-listing-empty')), findsNothing);
    await t.tap(find.byKey(const Key('all-listing-kind-shows')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('all-listing-empty')), findsOneWidget);
    expect(find.byType(AllServersPoster), findsNothing);
  });

  testWidgets('the kind argument picks the starting filter', (t) async {
    final sa = fakeServer('a');
    final a = FakeMergedSource(sa, recent: [
      item(sa, 'm1', addedAt: DateTime.utc(2024, 1, 2)),
      item(sa, 's1', kind: ItemKind.show, addedAt: DateTime.utc(2024, 1, 1)),
    ]);
    await pump(t, [a, FakeMergedSource(fakeServer('b'))],
        listing: AllServersListing.recentlyAdded, kind: LibraryKind.shows);
    expect(find.byType(AllServersPoster), findsOneWidget);
    expect(find.byKey(ValueKey('all-poster-${a.id.value}-s1')), findsOneWidget);
  });

  testWidgets('continue watching has no kind chips', (t) async {
    final s = fakeServer('a');
    await pump(
        t,
        [
          FakeMergedSource(s, resuming: [
            item(s, 'r1', lastPlayedAt: DateTime.utc(2024, 1, 1)),
          ]),
          FakeMergedSource(fakeServer('b')),
        ],
        listing: AllServersListing.continueWatching);
    expect(find.byType(AllServersPoster), findsOneWidget);
    expect(find.byKey(const Key('all-listing-kind-all')), findsNothing);
  });

  testWidgets('favorites lists every server\'s favourites', (t) async {
    final a = fakeServer('a'), b = fakeServer('b');
    await pump(
        t,
        [
          FakeMergedSource(a, favs: [item(a, 'f1')]),
          FakeMergedSource(b, favs: [item(b, 'f2')]),
        ],
        listing: AllServersListing.favorites);
    expect(find.byType(AllServersPoster), findsNWidgets(2));
  });
}
