import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/toast_harness.dart';
import 'fake_media_source.dart';

/// A second instance, so a test can tell one source's listing from another's.
const otherSourceId = SourceId('acc2:owner:bb22');

ItemSummary listingMovie(SourceId sid, String id, String title) => ItemSummary(
      ref: ItemRef(sourceId: sid, kind: ItemKind.movie, externalId: id),
      title: title,
      year: 2001,
    );

ItemSummary listingShow(SourceId sid, String id, String title,
        {int? unwatched}) =>
    ItemSummary(
      ref: ItemRef(sourceId: sid, kind: ItemKind.show, externalId: id),
      title: title,
      userState: UserState(unwatchedCount: unwatched),
    );

/// Every location the screen under test pushed, in order.
class PushedLocations {
  final all = <String>[];
  String get last => all.last;
}

/// Pumps [screen] at `/` over a router that records every other location it
/// pushes. Each of [sources] answers for its own id.
Future<PushedLocations> pumpListing(
  WidgetTester tester,
  Widget screen, {
  required List<FakeMediaSource> sources,
  List<Override> overrides = const [],
  Size size = const Size(1280, 900),
}) async {
  final pushed = PushedLocations();
  Widget recorder(BuildContext _, GoRouterState state) {
    pushed.all.add(state.uri.toString());
    return const SizedBox();
  }

  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => screen),
    for (final path in const [
      '/s/:id/movie/:item',
      '/s/:id/show/:item',
      '/s/:id/episode/:item',
      '/s/:id/collection/:collection',
      '/s/:id/search',
      '/s/:id/player/:item',
    ])
      GoRoute(path: path, builder: recorder),
  ]);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      for (final source in sources)
        mediaSourceProvider(source.id).overrideWithValue(source),
      // No artwork requests: a poster with a URL spins until the blocked
      // test HTTP client answers, which pumpAndSettle never outlasts.
      sourceArtworkProvider.overrideWith((ref, key) async => null),
      ...overrides,
    ],
    child: MaterialApp.router(routerConfig: router, builder: toastLayerBuilder),
  ));
  await tester.pumpAndSettle();
  return pushed;
}
