import 'dart:async';

import 'package:flutter/material.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/cache/fetch_log.dart';
import 'package:player/core/cache/invalidation_target.dart';
import 'package:player/core/cache/watcher_registry.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/core/sources/cache/source_cache.dart';
import 'package:player/core/sources/cache/source_codecs.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/cache/source_rules.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/all_servers/all_servers_cards.dart';
import 'package:player/presentation/screens/home/home_loading_skeleton.dart';
import 'package:player/presentation/screens/home/home_scope.dart';
import 'package:player/presentation/screens/home/home_screen.dart';
import 'package:player/presentation/screens/sources/continue_watching_card.dart';
import 'package:player/presentation/screens/sources/home_header.dart';
import 'package:player/presentation/screens/sources/source_home_hero.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:player/presentation/widgets/source_artwork.dart';
import 'package:player/presentation/widgets/window_chrome/window_title_row.dart';

import '../../../domain/merged/fake_merged_source.dart';
import '../../../test_utils/toast_harness.dart';
import '../sources/fake_media_source.dart';

late GoRouter homeRouter;

class _RecordingInvalidator implements Invalidator {
  final targets = <InvalidationTarget>[];

  @override
  Future<void> invalidate(Iterable<InvalidationTarget> targets) async {
    this.targets.addAll(targets);
  }

  @override
  Future<void> invalidateAll() async {}
}

/// Continue Watching holds a show, from a source that knows next up.
class _ShowHeroSource extends FakeResumingSource implements NextUp {
  _ShowHeroSource() : super(resuming: [fakeShow]);

  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.nextUp};

  @override
  Future<ItemSummary?> nextUp(ItemRef show) async => fakeEpisode(2);
}

/// Mounts Home for [scope] over [sources] and records every pushed location.
Future<List<String>> pumpHome(
  WidgetTester t,
  List<MediaSource> sources, {
  HomeScope scope = const AllServers(),
  bool settle = true,
  Size size = const Size(1280, 1800),
  List<Override> overrides = const [],
}) async {
  final pushed = <String>[];
  GoRoute record(String path) => GoRoute(
      path: path,
      builder: (_, s) {
        pushed.add(s.uri.toString());
        return const SizedBox();
      });
  homeRouter = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, __) => HomeScreen(scope: scope)),
    record('/all/:a'),
    record('/s/:id/:a'),
    record('/s/:id/:a/:b'),
    record('/s/:id/:a/:b/:c'),
  ]);
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(ProviderScope(
    overrides: [
      allServersSourcesProvider.overrideWithValue(sources),
      sourcesProvider.overrideWithValue([for (final s in sources) s.source]),
      for (final s in sources) mediaSourceProvider(s.id).overrideWithValue(s),
      allServersNeedSignInProvider.overrideWithValue(const []),
      // No artwork requests: a poster with a URL spins until the blocked test
      // HTTP client answers, which pumpAndSettle never outlasts.
      sourceArtworkProvider.overrideWith((ref, key) async => null),
      ...overrides,
    ],
    child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: homeRouter,
        builder: toastLayerBuilder),
  ));
  if (settle) {
    await t.pumpAndSettle();
  } else {
    await t.pump();
  }
  return pushed;
}

FakeMergedSource serverWith(String id) {
  final s = fakeServer(id);
  return FakeMergedSource(
    s,
    movies: [item(s, '${id}m', addedAt: DateTime.utc(2024))],
    resuming: [
      item(s, '${id}1',
          durationSeconds: 3600,
          lastPlayedAt: DateTime.utc(2024, 1, id == 'b' ? 2 : 1)),
    ],
    recent: [
      item(s, '${id}2', addedAt: DateTime.utc(2024, 1, 1)),
      item(s, '${id}3', kind: ItemKind.show, addedAt: DateTime.utc(2024, 1, 1)),
    ],
    favs: [item(s, '${id}4')],
  );
}

Key cardKey(MediaSource s, String id) =>
    ValueKey('home-continue-${s.id.value}-$id');

void main() {
  group('rows', () {
    testWidgets('hero, the four rails, then library rows, in order', (t) async {
      final a = serverWith('a'), b = serverWith('b');
      await pumpHome(t, [a, b]);
      double y(Key k) => t.getTopLeft(find.byKey(k)).dy;
      final keys = [
        const Key('home-hero'),
        const Key('home-continue-watching'),
        const Key('home-recent-movies'),
        const Key('home-recent-shows'),
        const Key('home-favorites'),
        Key('home-library-row-${a.id.value}-movies'),
      ];
      for (final k in keys) {
        expect(find.byKey(k), findsOneWidget, reason: '$k');
      }
      for (var i = 1; i < keys.length; i++) {
        expect(y(keys[i - 1]), lessThan(y(keys[i])), reason: '${keys[i]}');
      }
    });

    testWidgets('one server shows the same rows, its libraries unlabelled',
        (t) async {
      final a = serverWith('a');
      await pumpHome(t, [a], scope: OneServer(a.id));
      for (final k in [
        'home-hero',
        'home-continue-watching',
        'home-recent-movies',
        'home-recent-shows',
        'home-favorites',
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
      expect(find.text('Films'), findsOneWidget);
      expect(find.text('Films · Server a'), findsNothing,
          reason: 'one server needs no server labels');
    });

    testWidgets('two servers label cards and library rows', (t) async {
      final a = serverWith('a'), b = serverWith('b');
      // Tall enough that the lazy list builds both servers' library rows.
      await pumpHome(t, [a, b], size: const Size(1280, 3000));
      expect(find.text('Films · Server a'), findsOneWidget);
      expect(find.text('Films · Server b'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byKey(cardKey(a, 'a1')),
              matching: find.textContaining('Server a')),
          findsOneWidget);
    });

    testWidgets('an empty rail is hidden', (t) async {
      final s = fakeServer('a');
      await pumpHome(t, [
        FakeMergedSource(s, recent: [item(s, 'm', addedAt: DateTime.utc(2024))])
      ]);
      expect(find.byKey(const Key('home-recent-movies')), findsOneWidget);
      expect(find.byKey(const Key('home-recent-shows')), findsNothing);
      expect(find.byKey(const Key('home-favorites')), findsNothing);
      expect(find.byKey(const Key('home-continue-watching')), findsNothing);
    });

    testWidgets('no servers is empty, not an error', (t) async {
      await pumpHome(t, []);
      expect(find.byKey(const Key('source-error-retry')), findsNothing);
      expect(find.text('Nothing to show yet.'), findsOneWidget);
    });
  });

  group('navigation', () {
    Future<String> tapTitle(
        WidgetTester t, String key, List<String> pushed) async {
      await t.tap(find
          .descendant(of: find.byKey(Key(key)), matching: find.byType(InkWell))
          .first);
      await t.pumpAndSettle();
      return pushed.last;
    }

    testWidgets('All servers row titles open the merged listings', (t) async {
      final pushed = await pumpHome(t, [serverWith('a'), serverWith('b')]);
      expect(await tapTitle(t, 'home-recent-movies', pushed),
          '/all/recently-added?kind=movies');
      homeRouter.pop();
      await t.pumpAndSettle();
      expect(await tapTitle(t, 'home-favorites', pushed), '/all/favorites');
    });

    testWidgets('one server row titles open that server\'s listings',
        (t) async {
      final a = serverWith('a');
      final pushed = await pumpHome(t, [a], scope: OneServer(a.id));
      expect(await tapTitle(t, 'home-continue-watching', pushed),
          endsWith('/continue-watching'));
      expect(pushed.last, startsWith('/s/'));
      homeRouter.pop();
      await t.pumpAndSettle();
      expect(await tapTitle(t, 'home-recent-shows', pushed),
          endsWith('/recently-added'));
      expect(pushed.last, startsWith('/s/'));
    });

    testWidgets('a library title opens the library', (t) async {
      final a = serverWith('a');
      final pushed = await pumpHome(t, [a], scope: OneServer(a.id));
      await t.tap(find.byKey(Key('home-library-row-${a.id.value}-movies')));
      await t.pumpAndSettle();
      expect(pushed.last, endsWith('/library/movies'));
    });

    testWidgets('a Continue Watching card plays it', (t) async {
      final a = serverWith('a'), b = serverWith('b');
      final pushed = await pumpHome(t, [a, b]);
      await t.tap(find.byKey(cardKey(a, 'a1')));
      await t.pumpAndSettle();
      expect(Uri.parse(pushed.last).path, endsWith('/player/a1'));
    });
  });

  group('Continue Watching menu', () {
    testWidgets('remove drops the card', (t) async {
      final fake = FakeResumingSource();
      await pumpHome(t, [fake], scope: const OneServer(fakeSourceId));
      await t.longPress(find.byKey(cardKey(fake, 'e2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('home-continue-remove')));
      await t.pumpAndSettle();
      expect(fake.removed, [fakeResumingEpisode.ref]);
      expect(find.byKey(cardKey(fake, 'e2')), findsNothing);
    });

    testWidgets('a refused remove shows a toast and brings the card back',
        (t) async {
      final fake = FakeResumingSource()
        ..removeError = const SourceException.unreachable();
      await pumpHome(t, [fake], scope: const OneServer(fakeSourceId));
      await t.longPress(find.byKey(cardKey(fake, 'e2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('home-continue-remove')));
      await t.pumpAndSettle();
      expect(
          find.text('Could not reach this server. Check that it is running '
              'and on the network.'),
          findsOneWidget);
      expect(find.byKey(cardKey(fake, 'e2')), findsOneWidget);
    });

    testWidgets('an entry the source cannot remove offers details only',
        (t) async {
      final fake = FakeResumingSource()
        ..unremovable.add(fakeResumingEpisode.ref);
      await pumpHome(t, [fake], scope: const OneServer(fakeSourceId));
      await t.longPress(find.byKey(cardKey(fake, 'e2')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('home-continue-details')), findsOneWidget);
      expect(find.byKey(const Key('home-continue-remove')), findsNothing);
    });
  });

  group('failure and loading', () {
    testWidgets('a failed server shows the banner; retry reloads', (t) async {
      final a = serverWith('a');
      final down = FakeMergedSource(fakeServer('d'))
        ..failWith = const SourceException.unreachable();
      await pumpHome(t, [a, down]);
      expect(find.byKey(const Key('all-unavailable-banner')), findsOneWidget);
      down.failWith = null;
      await t.tap(find.byKey(const Key('all-unavailable-retry')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('all-unavailable-banner')), findsNothing);
    });

    testWidgets('every server failing shows the error view', (t) async {
      final a = FakeMergedSource(fakeServer('a'))
        ..failWith = const SourceException.unreachable();
      final b = FakeMergedSource(fakeServer('b'))
        ..failWith = const SourceException.unreachable();
      await pumpHome(t, [a, b]);
      expect(find.byKey(const Key('source-error-retry')), findsOneWidget);
    });

    testWidgets('one unreachable server shows the error view; retry recovers',
        (t) async {
      final fake =
          FakeMediaSource(failWith: const SourceException.unreachable());
      await pumpHome(t, [fake],
          scope: const OneServer(fakeSourceId), size: const Size(390, 844));
      expect(find.byKey(const Key('source-error-retry')), findsOneWidget);
      expect(find.text(fake.displayName), findsOneWidget,
          reason: 'the bar stays so the drawer and title are still there');
      fake.failWith = null;
      await t.tap(find.byKey(const Key('source-error-retry')));
      await t.pumpAndSettle();
      expect(find.text('Films'), findsOneWidget);
    });

    testWidgets('loading shows the skeleton', (t) async {
      final gate = Completer<void>();
      final a = serverWith('a')..gate = gate;
      await pumpHome(t, [a], settle: false);
      expect(find.byType(HomeLoadingSkeleton), findsOneWidget);
      gate.complete();
      await t.pumpAndSettle();
      expect(find.byType(HomeLoadingSkeleton), findsNothing);
    });

    testWidgets('pull to refresh refetches Continue Watching', (t) async {
      final fake = FakeResumingSource();
      await pumpHome(t, [fake],
          scope: const OneServer(fakeSourceId), size: const Size(1280, 900));
      await t.fling(
          find.byKey(const Key('home-list')), const Offset(0, 400), 1000);
      await t.pumpAndSettle();
      expect(fake.continueCalls, 2);
    });
  });

  group('chrome', () {
    testWidgets('the hero bleeds up to the window top', (t) async {
      await pumpHome(t, [serverWith('a')]);
      // The backdrop layer needs real artwork, which spins under the test
      // client; SourceHomeHero's own test covers its geometry. What Home owns
      // is the bleed: it must equal the gap above the hero's box.
      final bleed =
          t.widget<SourceHomeHero>(find.byType(SourceHomeHero)).bleedTop;
      expect(bleed, greaterThan(0));
      expect(bleed, t.getTopLeft(find.byKey(const Key('home-hero'))).dy);
      expect(find.byKey(WindowTitleRow.castKey), findsOneWidget);
    });

    testWidgets('All servers: desktop bar is titled All servers', (t) async {
      await pumpHome(t, [serverWith('a'), serverWith('b')],
          size: const Size(1280, 900));
      expect(
          find.descendant(
              of: find.byType(WindowTitleBar),
              matching: find.text('All servers')),
          findsOneWidget);
    });

    testWidgets('one server: phone bar names it and opens its search',
        (t) async {
      // No Continue Watching: the test font is wide enough that its row title
      // overflows a 390px phone.
      final fake = FakeMediaSource();
      final pushed = await pumpHome(t, [fake],
          scope: const OneServer(fakeSourceId), size: const Size(390, 844));
      expect(find.text(fake.displayName), findsOneWidget);
      await t.tap(find.byKey(homeSearchKey));
      await t.pumpAndSettle();
      expect(pushed.last, endsWith('/search'));
    });

    testWidgets('the skeleton matches the loaded hero height at 1280x800',
        (t) async {
      final gate = Completer<void>();
      final a = serverWith('a')..gate = gate;
      await pumpHome(t, [a], settle: false, size: const Size(1280, 800));
      final skeletonHero = t.getSize(find.byKey(HomeLoadingSkeleton.heroKey));
      gate.complete();
      await t.pumpAndSettle();
      final loadedHero = t.getSize(find.byKey(const Key('home-hero')));
      expect(skeletonHero.height, closeTo(loadedHero.height, 1));
      expect(
          t.widget(find.byKey(cardKey(a, 'a1'))), isA<ContinueWatchingCard>());
    });
  });

  group('ported from the old homes', () {
    final cw1 = fakeMovie(1, progress: 300);
    const base = '/s/acc1:owner:aa11';
    Key sourceCard(String id) =>
        ValueKey('home-continue-${fakeSourceId.value}-$id');

    testWidgets('a tap plays the first version and refreshes on return',
        (t) async {
      final fake = FakeResumingSource();
      final pushed =
          await pumpHome(t, [fake], scope: const OneServer(fakeSourceId));
      await t.tap(find.byKey(sourceCard('e2')));
      await t.pumpAndSettle();
      final location = Uri.parse(pushed.last);
      expect(location.path, '$base/player/e2');
      expect(location.queryParameters['kind'], 'episode');
      expect(fake.continueCalls, 1);
      homeRouter.pop();
      await t.pumpAndSettle();
      expect(fake.continueCalls, 2, reason: 'progress moved while playing');
    });

    testWidgets('details from the menu opens the item', (t) async {
      final fake = FakeResumingSource();
      final pushed =
          await pumpHome(t, [fake], scope: const OneServer(fakeSourceId));
      await t.longPress(find.byKey(sourceCard('e2')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('home-continue-details')));
      await t.pumpAndSettle();
      expect(pushed.last, '$base/episode/e2');
    });

    testWidgets('removing a card invalidates the Continue Watching rules',
        (t) async {
      final fake = FakeResumingSource(resuming: [cw1]);
      final invalidator = _RecordingInvalidator();
      await pumpHome(t, [fake],
          scope: const OneServer(fakeSourceId),
          overrides: [invalidatorProvider.overrideWithValue(invalidator)]);
      await t.longPress(find.byKey(sourceCard('m1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('home-continue-remove')));
      await t.pumpAndSettle();
      expect(fake.removed, [cw1.ref]);
      expect(invalidator.targets,
          containsAll(SourceRules.continueWatchingRemoved(fakeSourceId)));
    });

    testWidgets('a removal that outlives Home still invalidates the rules',
        (t) async {
      final gate = Completer<void>();
      final fake = FakeResumingSource(resuming: [cw1])..removeHold = gate;
      final invalidator = _RecordingInvalidator();
      await pumpHome(t, [fake],
          scope: const OneServer(fakeSourceId),
          overrides: [invalidatorProvider.overrideWithValue(invalidator)]);
      await t.longPress(find.byKey(sourceCard('m1')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('home-continue-remove')));
      await t.pump();
      homeRouter.go('/all/x');
      await t.pumpAndSettle();
      expect(find.byType(HomeScreen), findsNothing);
      gate.complete();
      await t.pumpAndSettle();
      expect(fake.removed, [cw1.ref]);
      expect(invalidator.targets,
          containsAll(SourceRules.continueWatchingRemoved(fakeSourceId)));
    });

    testWidgets('a failing Continue Watching hides the row, keeps the rest',
        (t) async {
      final fake = FakeResumingSource()
        ..continueError = const SourceException.unreachable();
      await pumpHome(t, [fake], scope: const OneServer(fakeSourceId));
      expect(find.byKey(const Key('home-continue-watching')), findsNothing);
      expect(find.text('Films'), findsOneWidget);
    });

    testWidgets('a source without Continue Watching has no such row',
        (t) async {
      await pumpHome(t, [FakeMediaSource()],
          scope: const OneServer(fakeSourceId));
      expect(find.byKey(const Key('home-continue-watching')), findsNothing);
      expect(find.byKey(const Key('home-hero')), findsNothing);
    });

    testWidgets('the hero features the first Continue Watching item',
        (t) async {
      await pumpHome(
          t,
          [
            FakeResumingSource(resuming: [cw1])
          ],
          scope: const OneServer(fakeSourceId));
      expect(
          find.descendant(
              of: find.byKey(const Key('home-hero')),
              matching: find.text(cw1.title)),
          findsOneWidget);
    });

    testWidgets('the hero play button plays the item', (t) async {
      final pushed = await pumpHome(
          t,
          [
            FakeResumingSource(resuming: [cw1])
          ],
          scope: const OneServer(fakeSourceId));
      await t.tap(find.byKey(const Key('source-home-hero-play')));
      await t.pumpAndSettle();
      expect(Uri.parse(pushed.last).path, '$base/player/m1');
    });

    testWidgets('the hero secondary button opens the item', (t) async {
      final pushed = await pumpHome(
          t,
          [
            FakeResumingSource(resuming: [cw1])
          ],
          scope: const OneServer(fakeSourceId));
      await t.tap(find.byKey(const Key('source-home-hero-more')));
      await t.pumpAndSettle();
      expect(pushed.last, '$base/movie/m1');
    });

    testWidgets('a featured show plays its next-up episode', (t) async {
      final pushed = await pumpHome(t, [_ShowHeroSource()],
          scope: const OneServer(fakeSourceId));
      await t.tap(find.byKey(const Key('source-home-hero-play')));
      await t.pumpAndSettle();
      expect(Uri.parse(pushed.last).path, '$base/player/e2');
    });

    // Requires --dart-define=MYDIA_FORCE_TV=true; CI runs it in the
    // television-tier step.
    testWidgets(
      'TV: Up from the first rail card focuses the hero play button',
      (t) async {
        await pumpHome(
            t,
            [
              FakeResumingSource(resuming: [cw1])
            ],
            scope: const OneServer(fakeSourceId));
        final card = find.byKey(sourceCard('m1'));
        Focus.of(t.element(find.descendant(
                of: card, matching: find.byKey(FocusHighlight.ringKey))))
            .requestFocus();
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await t.pumpAndSettle();
        var onPlay = false;
        FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
          if (e.widget.key == const Key('source-home-hero-play')) {
            onPlay = true;
            return false;
          }
          return true;
        });
        expect(onPlay, isTrue);
      },
      skip: !InputCapabilities.directionalPrimary,
    );

    testWidgets('a stored answer paints at once while the fetch is pending',
        (t) async {
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
      final fake = FakeResumingSource(resuming: [cw1])
        ..hold = Completer<void>();
      await pumpHome(t, [fake],
          scope: const OneServer(fakeSourceId),
          settle: false,
          overrides: [
            sourceCacheProvider.overrideWithValue(cache),
            fetchLogProvider.overrideWithValue(log),
          ]);
      for (var i = 0; i < 3; i++) {
        await t.pump();
      }
      expect(find.byKey(const Key('home-continue-watching')), findsOneWidget);
      expect(find.text(cw1.title), findsWidgets);
    });
  });

  group('labels and skeleton parity', () {
    const ids = ExternalIds(tmdb: '7');

    testWidgets('Continue Watching names its server, with +N for copies',
        (t) async {
      final a = fakeServer('a'), b = fakeServer('b');
      await pumpHome(t, [
        FakeMergedSource(a, resuming: [
          item(a, 'a1', ids: ids, lastPlayedAt: DateTime.utc(2024, 1, 2)),
          item(a, 'a2', lastPlayedAt: DateTime.utc(2024, 1, 1)),
        ]),
        FakeMergedSource(b, resuming: [
          item(b, 'b1', ids: ids, lastPlayedAt: DateTime.utc(2024, 1, 1)),
        ]),
      ]);
      final copies = find.byKey(ValueKey('home-continue-${a.id.value}-a1'));
      expect(find.descendant(of: copies, matching: find.text('Server a +1')),
          findsOneWidget);
      final single = find.byKey(ValueKey('home-continue-${a.id.value}-a2'));
      expect(find.descendant(of: single, matching: find.text('Server a')),
          findsOneWidget);
    });

    testWidgets(
        'Continue Watching renders landscape cards with the episode line',
        (t) async {
      final a = fakeServer('a'), b = fakeServer('b');
      await pumpHome(t, [
        FakeMergedSource(a, resuming: [
          ItemSummary(
            ref: ItemRef(
                sourceId: a.id, kind: ItemKind.episode, externalId: 'e1'),
            title: 'The Low Tide',
            showTitle: 'Saltmarsh',
            subtitle: 'S1 \u00b7 E2',
            lastPlayedAt: DateTime.utc(2024, 1, 1),
          ),
        ]),
        FakeMergedSource(b),
      ]);
      final card = find.byKey(ValueKey('home-continue-${a.id.value}-e1'));
      expect(t.widget(card), isA<ContinueWatchingCard>());
      expect(find.descendant(of: card, matching: find.text('Saltmarsh')),
          findsOneWidget);
      expect(
          find.descendant(
              of: card,
              matching: find
                  .text('S1 \u00b7 E2 \u00b7 The Low Tide \u00b7 Server a')),
          findsOneWidget,
          reason: 'the episode line carries the server name');
    });

    testWidgets('a Recently Added poster shows +1 for a title on both servers',
        (t) async {
      final a = fakeServer('a'), b = fakeServer('b');
      await pumpHome(t, [
        FakeMergedSource(a, recent: [
          item(a, 'a1', ids: ids, addedAt: DateTime.utc(2024, 1, 2)),
        ]),
        FakeMergedSource(b, recent: [
          item(b, 'b1', ids: ids, addedAt: DateTime.utc(2024, 1, 1)),
        ]),
      ]);
      final rail = find.byKey(const Key('home-recent-movies'));
      expect(find.descendant(of: rail, matching: find.byType(AllServersPoster)),
          findsOneWidget,
          reason: 'the two copies merge into one poster');
      expect(find.descendant(of: rail, matching: find.textContaining('+1')),
          findsOneWidget);
    });

    /// Height of the rail's card row: the ListView inside [rail].
    double railHeight(WidgetTester t, Finder rail) => t
        .getSize(find.descendant(of: rail, matching: find.byType(ListView)))
        .height;

    Future<void> expectRailParity(
        WidgetTester t, List<MediaSource> sources, HomeScope scope) async {
      final gate = Completer<void>();
      for (final s in sources.whereType<FakeMergedSource>()) {
        s.gate = gate;
      }
      await pumpHome(t, sources,
          scope: scope, settle: false, size: const Size(1280, 800));
      final skeleton =
          railHeight(t, find.byKey(HomeLoadingSkeleton.railKey).first);
      gate.complete();
      await t.pumpAndSettle();
      final rail = find.byKey(const Key('home-continue-watching'));
      final expected =
          ContinueWatchingCard.heightFor(t.element(rail), hasCaption: true);
      expect(skeleton, expected, reason: 'skeleton rail height');
      expect(railHeight(t, rail), expected, reason: 'loaded rail height');
    }

    testWidgets('the skeleton rail matches the loaded one, All servers',
        (t) async {
      await expectRailParity(
          t, [serverWith('a'), serverWith('b')], const AllServers());
    });

    testWidgets('the skeleton rail matches the loaded one, one server',
        (t) async {
      final a = fakeServer('a');
      final source = FakeMergedSource(a, resuming: [
        ItemSummary(
          ref:
              ItemRef(sourceId: a.id, kind: ItemKind.episode, externalId: 'e1'),
          title: 'The Low Tide',
          showTitle: 'Saltmarsh',
          subtitle: 'S1 \u00b7 E2',
          durationSeconds: 3600,
          lastPlayedAt: DateTime.utc(2024, 1, 1),
        ),
      ]);
      await expectRailParity(t, [source], OneServer(source.id));
    });
  });
}
