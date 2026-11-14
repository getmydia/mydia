// A library a paired player lends renders from the replicated index alone:
// Home lists its film and its detail page opens, and the backend is never
// asked to list anything.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/router/source_detail_routes.dart';
import 'package:player/core/sources/files/peer_files_sources.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/home/home_scope.dart';
import 'package:player/presentation/screens/home/home_screen.dart';
import 'package:player/presentation/screens/movie/movie_detail_screen.dart';
import 'package:player/presentation/widgets/media_poster.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../core/sources/files/files_fixture.dart';
import '../core/sources/files/peer_files_harness.dart';
import '../test_utils/toast_harness.dart';

void main() {
  testWidgets('peer_source_renders_home_and_detail_from_replicated_index',
      (tester) async {
    late PeerHarness h;
    await tester.runAsync(() async {
      h = PeerHarness(await FilesFixture.create(seed: false, inMemory: true));
      await h.seed(inMemory: true);
    });
    h.client.list.value = [lentFlocal()];
    final peerId = peerFilesSource(lentFlocal()).id;

    final router = GoRouter(routes: [
      GoRoute(
          path: '/', builder: (_, __) => HomeScreen(scope: OneServer(peerId))),
      sourceItemRoute(),
      ...sourceDetailRoutes(),
    ]);
    addTearDown(router.dispose);
    await tester.binding.setSurfaceSize(const Size(1280, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...h.overrides(InMemorySourceStore()),
        // No artwork requests: a URL keeps a spinner running and
        // pumpAndSettle never settles.
        sourceArtworkProvider.overrideWith((ref, key) async => null),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        builder: toastLayerBuilder,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ));
    await tester.pumpAndSettle();

    final card = find.descendant(
        of: find.byType(MediaPoster), matching: find.text('Quiet Meridian'));
    expect(card, findsWidgets);
    expect(find.byType(MovieDetailScreen), findsNothing);
    await tester.tap(card.first);
    await tester.pumpAndSettle();

    expect(router.state.uri.path, startsWith('/s/${peerId.value}/movie/'));
    expect(
        find.descendant(
            of: find.byType(MovieDetailScreen),
            matching: find.text('Quiet Meridian')),
        findsWidgets);

    final peerBackend =
        h.backends.entries.where((e) => e.key.id == peerId).single.value;
    expect(peerBackend.listed, isEmpty);
    expect(h.backends.keys.every((s) => s.id == peerId), isTrue);
  });
}
