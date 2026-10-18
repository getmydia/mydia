import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/sources/source_home_hero.dart';
import 'package:player/presentation/widgets/ambient_backdrop_provider.dart';
import 'package:player/presentation/widgets/artwork_image.dart';
import 'package:player/presentation/widgets/glass/glass_badge.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/shell_rail_inset.dart';

import 'fake_media_source.dart';

ItemSummary _movie({String? showTitle}) => ItemSummary(
      ref: const ItemRef(
        sourceId: fakeSourceId,
        kind: ItemKind.movie,
        externalId: 'night-ferry',
      ),
      title: 'Night Ferry',
      showTitle: showTitle,
      year: 2011,
      overview: 'A ferry crosses the saltmarsh after dark. ' * 8,
      poster: const ArtworkRef('/art/night-ferry'),
      backdrop: const ArtworkRef('/backdrop/night-ferry'),
    );

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Size size, {
  ItemSummary? item,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(overrides: [
    mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
  ]);
  addTearDown(container.dispose);
  // The controller is auto-dispose; keep it alive to read what was published.
  container.listen(ambientBackdropControllerProvider, (_, __) {});
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: SourceHomeHero(
            sourceId: fakeSourceId,
            item: item ?? _movie(),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  const posterKey = Key('source-home-hero-poster');
  const playKey = Key('source-home-hero-play');
  const moreKey = Key('source-home-hero-more');

  setUp(() => LiquidGlassSupport.debugPlatformOverride = false);
  tearDown(() => LiquidGlassSupport.debugPlatformOverride = null);

  group('on iOS and macOS', () {
    setUp(() => LiquidGlassSupport.debugPlatformOverride = true);

    testWidgets('Play and the secondary action are glass and still tap',
        (tester) async {
      await _pump(tester, const Size(1280, 800),
          item: _movie(showTitle: 'Saltmarsh'));
      expect(
        find.descendant(
            of: find.byKey(playKey), matching: find.byType(GlassSurface)),
        findsOneWidget,
      );
      expect(find.byType(FilledButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byKey(moreKey), findsOneWidget);
      expect(find.text('All episodes'), findsOneWidget);
      // Both pills share a height.
      expect(
        tester.getSize(find.byKey(moreKey)).height,
        tester.getSize(find.byKey(playKey)).height - 6,
      );
      // The harness has no router, so check the taps are wired rather than
      // firing them: both pills carry a live InkWell.
      expect(tester.widget<InkWell>(find.byKey(moreKey)).onTap, isNotNull);
      expect(
        tester
            .widget<InkWell>(find.descendant(
                of: find.byKey(playKey), matching: find.byType(InkWell)))
            .onTap,
        isNotNull,
      );
    });

    testWidgets('narrow: both pills fill the content width', (tester) async {
      await _pump(tester, const Size(400, 800));
      final play = tester.getSize(find.byKey(playKey));
      final more = tester.getSize(find.byKey(moreKey));
      expect(more.width, play.width - 6);
    });

    testWidgets('the episode chip is a glass badge', (tester) async {
      await _pump(tester, const Size(1280, 800),
          item: _movie(showTitle: 'Saltmarsh'));
      expect(find.byType(GlassBadge), findsWidgets);
    });

    testWidgets('every glass surface shares one BackdropGroup pass',
        (tester) async {
      await _pump(tester, const Size(1280, 800),
          item: _movie(showTitle: 'Saltmarsh'));
      final surfaces =
          tester.widgetList<GlassSurface>(find.byType(GlassSurface)).toList();
      // Chips (subtitle-less item: year), Play and the secondary action.
      expect(surfaces.length, greaterThanOrEqualTo(3));
      expect(surfaces.every((s) => s.live && s.grouped), isTrue);
      expect(find.byType(BackdropGroup), findsOneWidget);
      for (final surface in find.byType(GlassSurface).evaluate()) {
        expect(
          find.ancestor(
            of: find.byWidget(surface.widget),
            matching: find.byType(BackdropGroup),
          ),
          findsOneWidget,
        );
      }
    });
  });

  testWidgets('off Apple there is no BackdropGroup', (tester) async {
    await _pump(tester, const Size(1280, 800));
    expect(find.byType(GlassSurface), findsNothing);
    expect(find.byType(BackdropGroup), findsNothing);
  });

  testWidgets('wide: a 248x360 poster with the title to its right',
      (tester) async {
    await _pump(tester, const Size(1280, 800));

    expect(tester.getSize(find.byKey(posterKey)), const Size(248, 360));
    expect(
      tester.getTopLeft(find.text('Night Ferry')).dx,
      greaterThan(tester.getTopRight(find.byKey(posterKey)).dx),
    );
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byKey(playKey), findsOneWidget);
    expect(find.byType(OutlinedButton), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(moreKey),
        matching: find.text('More info'),
      ),
      findsOneWidget,
    );
    final overview =
        tester.widget<Text>(find.textContaining('A ferry crosses'));
    expect(overview.maxLines, 2);
  });

  testWidgets('an episode offers All episodes and names its series',
      (tester) async {
    await _pump(tester, const Size(1280, 800),
        item: _movie(showTitle: 'Saltmarsh'));

    expect(find.text('All episodes'), findsOneWidget);
    expect(find.text('Saltmarsh'), findsOneWidget);
  });

  testWidgets('narrow: a centred 60% poster over full-width buttons',
      (tester) async {
    await _pump(tester, const Size(400, 800));

    final poster = find.byKey(posterKey);
    expect(tester.getSize(poster).width, 240);
    expect(tester.getCenter(poster).dx, 200);
    final play = tester.getSize(find.byKey(playKey));
    final more = tester.getSize(find.byKey(moreKey));
    final left = tester.getTopLeft(find.byKey(playKey)).dx;
    // The content width: the view minus the padding on both sides.
    expect(play.width, 400 - 2 * left);
    expect(more.width, play.width);
  });

  testWidgets('publishes the credentialed artwork as the ambient backdrop',
      (tester) async {
    final container = await _pump(tester, const Size(1280, 800));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }

    final source = container.read(ambientBackdropControllerProvider);
    expect(source.id, source.cacheKey,
        reason: 'ids repeat across servers; the cache key does not');
    expect(source.imageUrl, contains('/backdrop/night-ferry'));
    expect(source.headers, {'X-Plex-Token': 'tok'});
    expect(source.cacheKey, isNotNull);
  });

  group('backdrop', () {
    const backdropKey = SourceHomeHero.backdropKey;
    const railInset = 96.0;

    // The Home page as the shell lays it out: full width, rows inset by the
    // rail's footprint, which it also publishes.
    Future<void> pumpInShell(
      WidgetTester tester,
      Size size, {
      ItemSummary? item,
      double inset = railInset,
      bool reduceMotion = false,
      double bleedTop = 0,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduceMotion,
            ),
            child: child!,
          ),
          home: Scaffold(
            // The page spans the window and publishes the rail's footprint;
            // the list insets its rows, the hero's backdrop reaches back.
            body: ShellRailInset(
              left: inset,
              child: SingleChildScrollView(
                padding: EdgeInsets.only(left: inset),
                child: SourceHomeHero(
                  sourceId: fakeSourceId,
                  item: item ?? _movie(),
                  bleedTop: bleedTop,
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    ArtworkImage image(WidgetTester tester) => tester.widget<ArtworkImage>(
          find.descendant(
            of: find.byKey(backdropKey),
            matching: find.byType(ArtworkImage),
          ),
        );

    testWidgets('wide: runs under the rail to the window edge and top',
        (tester) async {
      await pumpInShell(tester, const Size(1280, 800));

      final backdrop = tester.getRect(find.byKey(backdropKey));
      final hero = tester.getRect(find.byType(SourceHomeHero));
      expect(backdrop.left, 0, reason: 'under the rail');
      expect(backdrop.top, 0);
      expect(backdrop.right, 1280);
      expect(backdrop.bottom, hero.bottom);
      expect(hero.left, railInset);
    });

    testWidgets('the art is masked out at the bottom', (tester) async {
      await pumpInShell(tester, const Size(1280, 800));

      final masks = find.descendant(
        of: find.byKey(backdropKey),
        matching: find.byType(ShaderMask),
      );
      expect(masks, findsOneWidget, reason: 'the bottom fade only');
      expect(tester.widget<ShaderMask>(masks).blendMode, BlendMode.dstIn,
          reason: 'it dissolves the art, it does not tint it');
    });

    testWidgets('wide: the poster and text sit where they did before',
        (tester) async {
      await pumpInShell(tester, const Size(1280, 800));

      // 32 padding past the column's left edge, 24 below the top.
      expect(tester.getRect(find.byKey(posterKey)),
          const Rect.fromLTWH(railInset + 32, 24, 248, 360));
      expect(
        tester.getTopLeft(find.text('Night Ferry')).dx,
        railInset + 32 + 248 + 36,
      );
    });

    testWidgets('wide: one image layer, no blur', (tester) async {
      await pumpInShell(tester, const Size(1280, 800));

      expect(
        find.descendant(
            of: find.byKey(backdropKey), matching: find.byType(ArtworkImage)),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byKey(backdropKey), matching: find.byType(ImageFiltered)),
        findsNothing,
      );
      expect(
        find.ancestor(
            of: find.byKey(backdropKey),
            matching: find.byType(RepaintBoundary)),
        findsWidgets,
      );
    });

    testWidgets('paints the backdrop art, credentials included',
        (tester) async {
      await pumpInShell(tester, const Size(1280, 800));

      final art = image(tester);
      expect(art.imageUrl, contains('/backdrop/night-ferry'));
      expect(art.headers, {'X-Plex-Token': 'tok'});
      expect(art.cacheKey, isNotNull);
    });

    testWidgets('falls back to the poster only without a backdrop',
        (tester) async {
      await pumpInShell(
        tester,
        const Size(1280, 800),
        item: const ItemSummary(
          ref: ItemRef(
            sourceId: fakeSourceId,
            kind: ItemKind.movie,
            externalId: 'night-ferry',
          ),
          title: 'Night Ferry',
          poster: ArtworkRef('/art/night-ferry'),
        ),
      );

      expect(image(tester).imageUrl, contains('/art/night-ferry'));
    });

    testWidgets('no art at all: no backdrop and no error', (tester) async {
      await pumpInShell(
        tester,
        const Size(1280, 800),
        item: const ItemSummary(
          ref: ItemRef(
            sourceId: fakeSourceId,
            kind: ItemKind.movie,
            externalId: 'night-ferry',
          ),
          title: 'Night Ferry',
        ),
      );

      expect(find.byKey(backdropKey), findsNothing);
      expect(find.text('Night Ferry'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('bleedTop lifts it above the hero', (tester) async {
      await pumpInShell(tester, const Size(1280, 800), bleedTop: 40);

      expect(tester.getTopLeft(find.byKey(backdropKey)).dy, -40);
      expect(tester.getTopLeft(find.byKey(posterKey)).dy, 24);
    });

    testWidgets('fades in when motion is allowed', (tester) async {
      await pumpInShell(tester, const Size(1280, 800));
      expect(image(tester).fadeInDuration, const Duration(milliseconds: 500));
    });

    testWidgets('does not fade under reduced motion', (tester) async {
      await pumpInShell(tester, const Size(1280, 800), reduceMotion: true);
      expect(image(tester).fadeInDuration, Duration.zero);
    });

    testWidgets('narrow: behind the poster, title on the plain ground',
        (tester) async {
      // No rail below the wide layout.
      await pumpInShell(tester, const Size(400, 800), inset: 0);

      final backdrop = tester.getRect(find.byKey(backdropKey));
      final poster = tester.getRect(find.byKey(posterKey));
      expect(backdrop.left, 0);
      expect(backdrop.right, 400);
      expect(backdrop.top, 0);
      expect(backdrop.overlaps(poster), isTrue);
      expect(backdrop.bottom, poster.bottom + 20,
          reason: 'it ends where the title block begins');
      expect(
        tester.getTopLeft(find.text('Night Ferry')).dy,
        greaterThanOrEqualTo(backdrop.bottom),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow: the backdrop paints under the poster', (tester) async {
      await pumpInShell(tester, const Size(400, 800), inset: 0);

      final stack = tester.widget<Stack>(find
          .ancestor(of: find.byKey(backdropKey), matching: find.byType(Stack))
          .first);
      final backdropIndex = stack.children.indexWhere(
        (w) => w is Positioned && w.child.key == backdropKey,
      );
      expect(backdropIndex, 0, reason: 'first child paints first');
    });
  });
}
