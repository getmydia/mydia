import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/router/navigator_keys.dart';
import 'package:player/core/router/source_detail_routes.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/detail/detail_links.dart';
import 'package:player/presentation/screens/episode/episode_detail_screen.dart';
import 'package:player/presentation/screens/movie/movie_detail_screen.dart';
import 'package:player/presentation/screens/show/show_detail_screen.dart';
import 'package:player/presentation/screens/sources/source_browse_providers.dart';
import 'package:player/presentation/screens/sources/source_error_view.dart';
import 'package:player/presentation/screens/sources/source_item_screen.dart';
import 'package:player/presentation/widgets/play_button.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../presentation/screens/sources/fake_media_source.dart';
import '../../test_utils/toast_harness.dart';

final _id = fakeSourceId.value;

class _OrphanSeason extends FakeMediaSource {
  @override
  Future<ItemDetail> item(ItemRef ref) async =>
      const ItemDetail(summary: fakeSeason);
}

class _CountingSource extends FakeMediaSource {
  int itemCalls = 0;

  @override
  Future<ItemDetail> item(ItemRef ref) {
    itemCalls++;
    return super.item(ref);
  }
}

Future<GoRouter> pumpRouterAt(
  WidgetTester tester,
  String location, {
  FakeMediaSource? fake,
  List<RouteBase> extraRoutes = const [],
}) async {
  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: location,
    routes: [sourceItemRoute(), ...sourceDetailRoutes(), ...extraRoutes],
  );
  addTearDown(router.dispose);
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaSourceProvider(fakeSourceId)
          .overrideWithValue(fake ?? FakeMediaSource()),
      sourceArtworkProvider.overrideWith((ref, key) async => null),
    ],
    child: MaterialApp.router(routerConfig: router, builder: toastLayerBuilder),
  ));
  await tester.pumpAndSettle();
  return router;
}

void main() {
  testWidgets('a source movie on the generic route opens the movie screen',
      (tester) async {
    final router = await pumpRouterAt(tester, '/s/$_id/item/movie/m1');
    expect(find.byType(MovieDetailScreen), findsOneWidget);
    expect(find.text('Invented Film 1'), findsWidgets);
    expect(router.state.uri.path, '/s/$_id/movie/m1');
  });

  testWidgets('a source show opens the show screen with its episodes',
      (tester) async {
    await pumpRouterAt(tester, '/s/$_id/show/s1');
    expect(find.byType(ShowDetailScreen), findsOneWidget);
    expect(find.text('Invented Episode 1'), findsOneWidget);
  });

  testWidgets('a source movie is refetched after the player pops',
      (tester) async {
    final fake = _CountingSource();
    await pumpRouterAt(
      tester,
      '/s/$_id/movie/m1',
      fake: fake,
      extraRoutes: [
        GoRoute(
          path: '/s/:sourceId/player/:itemId',
          builder: (_, __) => const Scaffold(body: Text('player stub')),
        ),
      ],
    );
    final before = fake.itemCalls;
    expect(before, greaterThan(0));

    await tester.tap(find.byType(PlayButton));
    await tester.pumpAndSettle();
    expect(find.text('player stub'), findsOneWidget);

    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(MovieDetailScreen), findsOneWidget);
    expect(fake.itemCalls, greaterThan(before));
  });

  testWidgets('a season opens its show on that season', (tester) async {
    await pumpRouterAt(tester, '/s/$_id/season/se1');
    expect(find.byType(ShowDetailScreen), findsOneWidget);
    expect(find.text('Invented Episode 1'), findsOneWidget);
  });

  testWidgets('a season without a show shows an error', (tester) async {
    await pumpRouterAt(tester, '/s/$_id/season/se1', fake: _OrphanSeason());
    expect(find.byType(ShowDetailScreen), findsNothing);
    expect(find.byType(SourceErrorView), findsOneWidget);
  });

  testWidgets('a source show on the generic route redirects to the show',
      (tester) async {
    final router = await pumpRouterAt(tester, '/s/$_id/item/show/s1');
    expect(find.byType(ShowDetailScreen), findsOneWidget);
    expect(router.state.uri.path, '/s/$_id/show/s1');
  });

  testWidgets('a source episode opens the episode screen', (tester) async {
    await pumpRouterAt(tester, '/s/$_id/item/episode/e1');
    expect(find.byType(EpisodeDetailScreen), findsOneWidget);
  });

  testWidgets('a source video keeps the generic screen', (tester) async {
    await pumpRouterAt(tester, '/s/$_id/item/video/v1');
    expect(find.byType(SourceItemScreen), findsOneWidget);
  });

  testWidgets('Mydia-only controls are absent on a source movie',
      (tester) async {
    await pumpRouterAt(tester, '/s/$_id/movie/m1');
    expect(find.text('Invented Film 1'), findsWidgets);
    expect(find.text('Watched'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
    expect(find.text('Info'), findsNothing);
    expect(find.text('Favorite'), findsNothing);
  });

  test('sourceItemLocation points at detail routes except video and folder',
      () {
    ItemRef ref(ItemKind k) =>
        ItemRef(sourceId: fakeSourceId, kind: k, externalId: 'x 1');
    expect(sourceItemLocation(ref(ItemKind.movie)), '/s/$_id/movie/x%201');
    expect(sourceItemLocation(ref(ItemKind.season)), '/s/$_id/season/x%201');
    expect(sourceItemLocation(ref(ItemKind.video)), '/s/$_id/item/video/x%201');
    expect(
        sourceItemLocation(ref(ItemKind.folder)), '/s/$_id/item/folder/x%201');
    expect(sourceItemLocation(ref(ItemKind.show)),
        detailLocation(SourceTarget(ref(ItemKind.show))));
  });
}
