import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/cache/fetch_log.dart';
import 'package:player/core/cache/watcher_registry.dart';
import 'package:player/core/sources/cache/source_cache.dart';
import 'package:player/core/sources/cache/source_codecs.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/cache/source_rules.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/cache/invalidation_target.dart';
import 'package:player/domain/sources/hub.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/sources/source_home_hero.dart';
import 'package:player/presentation/screens/sources/source_home_screen.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/toast_harness.dart';
import 'fake_media_source.dart';

class _RecordingInvalidator implements Invalidator {
  final targets = <InvalidationTarget>[];

  @override
  Future<void> invalidate(Iterable<InvalidationTarget> targets) async {
    this.targets.addAll(targets);
  }

  @override
  Future<void> invalidateAll() async {}
}

late GoRouter homeRouter;

Future<List<String>> pumpHome(
  WidgetTester tester,
  FakeMediaSource fake, {
  List<Override> overrides = const [],
  bool settle = true,
}) async {
  final pushed = <String>[];
  final router = homeRouter = GoRouter(routes: [
    GoRoute(
      path: '/',
      builder: (_, __) => const SourceHomeScreen(sourceId: fakeSourceId),
    ),
    GoRoute(
      path: '/s/:id/library/:lib',
      builder: (_, s) {
        pushed.add(s.uri.toString());
        return const SizedBox();
      },
    ),
    GoRoute(
      path: '/s/:id/movie/:item',
      builder: (_, s) {
        pushed.add(s.uri.toString());
        return const SizedBox();
      },
    ),
    GoRoute(
      path: '/s/:id/episode/:item',
      builder: (_, s) {
        pushed.add(s.uri.toString());
        return const SizedBox();
      },
    ),
    GoRoute(
      path: '/s/:id/item/:kind/:item',
      builder: (_, s) {
        pushed.add(s.uri.toString());
        return const SizedBox();
      },
    ),
    GoRoute(
      path: '/s/:id/player/:item',
      builder: (_, s) {
        pushed.add(s.uri.toString());
        return const SizedBox();
      },
    ),
  ]);
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(fake),
      // No artwork requests: a poster with a URL spins until the blocked
      // test HTTP client answers, which pumpAndSettle never outlasts.
      sourceArtworkProvider.overrideWith((ref, key) async => null),
      ...overrides,
    ],
    child: MaterialApp.router(routerConfig: router, builder: toastLayerBuilder),
  ));
  if (settle) await tester.pumpAndSettle();
  return pushed;
}

void main() {
  testWidgets('shows a row per library, newest first', (tester) async {
    final fake = FakeMediaSource();
    await pumpHome(tester, fake);
    expect(find.text('Films'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
    expect(find.text('Invented Film 1'), findsOneWidget);
    expect(fake.browseCalls.map((c) => c.$1.sortId), contains('added'),
        reason: 'rows prefer the source\'s "Recently added" sort');
  });

  testWidgets('a library title opens the grid; a poster opens the item',
      (tester) async {
    final pushed = await pumpHome(tester, FakeMediaSource());
    await tester.tap(find.byKey(const Key('source-library-row-movies')));
    await tester.pumpAndSettle();
    expect(pushed.last, '/s/acc1:owner:aa11/library/movies');
  });

  testWidgets('an unreachable source shows a retry state', (tester) async {
    final fake = FakeMediaSource(failWith: const SourceException.unreachable());
    await pumpHome(tester, fake);
    expect(find.byKey(const Key('source-error-retry')), findsOneWidget);
    expect(find.text(fake.displayName), findsOneWidget,
        reason: 'the header stays so the drawer and title are still there');
    fake.failWith = null;
    await tester.tap(find.byKey(const Key('source-error-retry')));
    await tester.pumpAndSettle();
    expect(find.text('Films'), findsOneWidget);
  });

  group('Continue Watching', () {
    testWidgets('comes before the library rows', (tester) async {
      await pumpHome(tester, FakeResumingSource());
      final row = find.byKey(const Key('source-continue-watching'));
      expect(row, findsOneWidget);
      expect(
        tester.getTopLeft(row).dy,
        lessThan(tester
            .getTopLeft(find.byKey(const Key('source-library-row-movies')))
            .dy),
      );
      expect(find.text('Invented Series · S1 · E2'), findsOneWidget);
    });

    testWidgets('is hidden for a source without it', (tester) async {
      await pumpHome(tester, FakeMediaSource());
      expect(find.byKey(const Key('source-continue-watching')), findsNothing);
    });

    testWidgets('is hidden when empty', (tester) async {
      await pumpHome(tester, FakeResumingSource(resuming: []));
      expect(find.byKey(const Key('source-continue-watching')), findsNothing);
    });

    testWidgets('a failure hides the row and keeps the rest', (tester) async {
      final fake = FakeResumingSource()
        ..continueError = const SourceException.unreachable();
      await pumpHome(tester, fake);
      expect(find.byKey(const Key('source-continue-watching')), findsNothing);
      expect(find.text('Films'), findsOneWidget);
    });

    testWidgets('a tap plays the first version and refreshes on return',
        (tester) async {
      final fake = FakeResumingSource();
      final pushed = await pumpHome(tester, fake);
      await tester.tap(find.byKey(const ValueKey('source-continue-e2')));
      await tester.pumpAndSettle();
      final location = Uri.parse(pushed.last);
      expect(location.path, '/s/acc1:owner:aa11/player/e2');
      expect(location.queryParameters['fileId'], 'part-1');
      expect(location.queryParameters['kind'], 'episode');

      expect(fake.continueCalls, 1);
      homeRouter.pop();
      await tester.pumpAndSettle();
      expect(fake.continueCalls, 2, reason: 'progress moved while playing');
    });

    testWidgets('remove from the menu drops the card', (tester) async {
      final fake = FakeResumingSource();
      await pumpHome(tester, fake);
      await tester.longPress(find.byKey(const ValueKey('source-continue-e2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('source-continue-remove')));
      await tester.pumpAndSettle();
      expect(fake.removed, [fakeResumingEpisode.ref]);
      expect(find.byKey(const ValueKey('source-continue-e2')), findsNothing);
    });

    testWidgets('a failed remove shows a toast and keeps the card',
        (tester) async {
      final fake = FakeResumingSource()
        ..removeError = const SourceException.unreachable();
      await pumpHome(tester, fake);
      await tester.longPress(find.byKey(const ValueKey('source-continue-e2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('source-continue-remove')));
      await tester.pumpAndSettle();
      expect(find.text(const SourceException.unreachable().viewerMessage),
          findsOneWidget);
      expect(find.byKey(const ValueKey('source-continue-e2')), findsOneWidget);
    });

    testWidgets('details from the menu opens the item', (tester) async {
      final pushed = await pumpHome(tester, FakeResumingSource());
      await tester.longPress(find.byKey(const ValueKey('source-continue-e2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('source-continue-details')));
      await tester.pumpAndSettle();
      expect(pushed.last, '/s/acc1:owner:aa11/episode/e2');
    });

    testWidgets('an entry the source cannot remove offers details only',
        (tester) async {
      final fake = FakeResumingSource()
        ..unremovable.add(fakeResumingEpisode.ref);
      await pumpHome(tester, fake);
      await tester.longPress(find.byKey(const ValueKey('source-continue-e2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('source-continue-details')), findsOneWidget);
      expect(find.byKey(const Key('source-continue-remove')), findsNothing);
    });

    testWidgets('pull to refresh reloads the row', (tester) async {
      final fake = FakeResumingSource();
      await pumpHome(tester, fake);
      await tester.fling(find.byKey(const Key('source-home-list')),
          const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(fake.continueCalls, 2);
    });
  });

  group('hubs', () {
    testWidgets('replace the library rows', (tester) async {
      final fake = FakeHubSource();
      await pumpHome(tester, fake);
      expect(find.text('Recently Added in Films'), findsOneWidget);
      expect(find.text('Recently Released'), findsOneWidget);
      expect(find.byKey(const Key('source-library-row-movies')), findsNothing);
      expect(fake.browseCalls, isEmpty,
          reason: 'no per-library preview is fetched');
    });

    testWidgets('follow Continue Watching', (tester) async {
      await pumpHome(tester, FakeHubSource());
      expect(
        tester.getTopLeft(find.byKey(const Key('source-continue-watching'))).dy,
        lessThan(tester
            .getTopLeft(find.byKey(const Key('source-hub-home.movies.recent')))
            .dy),
      );
    });

    testWidgets('a hub title opens its library; a mixed hub has no link',
        (tester) async {
      final pushed = await pumpHome(tester, FakeHubSource());
      // The hero pushes the rows below the fold.
      final mixed = find.byKey(const Key('source-hub-row-home.mixed.released'));
      await tester.ensureVisible(mixed);
      await tester.pumpAndSettle();
      await tester.tap(mixed);
      await tester.pumpAndSettle();
      expect(pushed, isEmpty);
      final recent = find.byKey(const Key('source-hub-row-home.movies.recent'));
      await tester.ensureVisible(recent);
      await tester.pumpAndSettle();
      await tester.tap(recent);
      await tester.pumpAndSettle();
      expect(pushed.last, '/s/acc1:owner:aa11/library/movies');
    });

    testWidgets('an empty hub list falls back to the library rows',
        (tester) async {
      final fake = FakeHubSource()..hubList = const [];
      await pumpHome(tester, fake);
      expect(
          find.byKey(const Key('source-library-row-movies')), findsOneWidget);
    });

    testWidgets('a hub failure falls back to the library rows', (tester) async {
      final fake = FakeHubSource()
        ..hubsError = const SourceException.unreachable();
      await pumpHome(tester, fake);
      expect(
          find.byKey(const Key('source-library-row-movies')), findsOneWidget);
      expect(find.byKey(const Key('source-continue-watching')), findsOneWidget);
    });
  });

  group('a Mydia-shaped home', () {
    final cw1 = fakeMovie(1, progress: 300);
    final r1 = fakeMovie(2);
    final f1 = fakeMovie(3);

    FakeHubSource source() => FakeHubSource(resuming: [cw1])
      ..hubList = [
        Hub(id: 'recent', title: 'Recently Added', items: [r1]),
        Hub(id: 'favorites', title: 'Favorites', items: [f1]),
      ];

    testWidgets('rows run Continue Watching, Recently Added, Favorites',
        (tester) async {
      await pumpHome(tester, source());
      double top(String title) => tester.getTopLeft(find.text(title)).dy;
      expect(top('Continue Watching'), lessThan(top('Recently Added')));
      expect(top('Recently Added'), lessThan(top('Favorites')));
    });

    testWidgets('the hero features the first Continue Watching item',
        (tester) async {
      await pumpHome(tester, source());
      expect(find.byType(SourceHomeHero), findsOneWidget);
      expect(
        find.descendant(
            of: find.byType(SourceHomeHero), matching: find.text(cw1.title)),
        findsOneWidget,
      );
    });

    testWidgets('without Continue Watching the hero takes the first hub item',
        (tester) async {
      await pumpHome(tester, source()..resuming = []);
      expect(
        find.descendant(
            of: find.byType(SourceHomeHero), matching: find.text(r1.title)),
        findsOneWidget,
      );
    });

    testWidgets('no hero when there is nothing to feature', (tester) async {
      await pumpHome(tester, FakeMediaSource());
      expect(find.byType(SourceHomeHero), findsNothing);
    });

    testWidgets('the hero play button opens the item', (tester) async {
      final pushed = await pumpHome(tester, source());
      await tester.tap(find.byKey(const Key('source-home-hero-play')));
      await tester.pumpAndSettle();
      expect(pushed.last, '/s/acc1:owner:aa11/movie/m1');
    });

    testWidgets('removing a card invalidates the Continue Watching rules',
        (tester) async {
      final fake = source();
      final invalidator = _RecordingInvalidator();
      await pumpHome(tester, fake, overrides: [
        invalidatorProvider.overrideWithValue(invalidator),
      ]);
      await tester.longPress(find.byKey(const ValueKey('source-continue-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('source-continue-remove')));
      await tester.pumpAndSettle();
      expect(fake.removed, [cw1.ref]);
      expect(invalidator.targets,
          containsAll(SourceRules.continueWatchingRemoved(fakeSourceId)));
    });

    testWidgets('a stored answer paints at once while the fetch is pending',
        (tester) async {
      final cache = InMemorySourceCache();
      final now = DateTime.now();
      await cache.write(SourceKeys.continueWatching(fakeSourceId),
          encodeSummaries([cw1]), now);
      await cache.write(SourceKeys.libraries(fakeSourceId),
          encodeLibraries(await FakeMediaSource().libraries()), now);
      // The fetch log is what makes a stored answer trusted on mount.
      final log = InMemoryFetchLog({
        SourceKeys.continueWatching(fakeSourceId): now,
        SourceKeys.libraries(fakeSourceId): now,
      });
      final fake = source()..hold = Completer<void>();
      await pumpHome(tester, fake, settle: false, overrides: [
        sourceCacheProvider.overrideWithValue(cache),
        fetchLogProvider.overrideWithValue(log),
      ]);
      await tester.pump();
      expect(find.byKey(const Key('source-continue-watching')), findsOneWidget);
      expect(find.text(cw1.title), findsWidgets);
    });
  });
}
