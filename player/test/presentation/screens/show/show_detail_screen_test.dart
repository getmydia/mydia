import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/show/show_detail_screen.dart';
import 'package:player/presentation/widgets/cast_rail.dart';
import 'package:player/presentation/widgets/detail_action_row.dart';
import 'package:player/presentation/widgets/episode_rail_card.dart';
import 'package:player/presentation/widgets/hero_play_control.dart';
import 'package:player/presentation/widgets/play_button.dart';

import '../detail/detail_harness.dart';
import '../sources/fake_media_source.dart';

const _show =
    ItemRef(sourceId: fakeSourceId, kind: ItemKind.show, externalId: 'sh-1');

ItemRef _seasonRef(int n) =>
    ItemRef(sourceId: fakeSourceId, kind: ItemKind.season, externalId: 'se-$n');

ItemSummary _episode(
  int number, {
  int season = 1,
  bool watched = false,
  int? positionSeconds,
}) =>
    ItemSummary(
      ref: ItemRef(
        sourceId: fakeSourceId,
        kind: ItemKind.episode,
        externalId: 'ep-$season-$number',
      ),
      title: 'Episode $number',
      index: number,
      parentIndex: season,
      overview: 'Overview for episode $number.',
      durationSeconds: 2580,
      defaultVersionId: 'file-$season-$number',
      userState: UserState(watched: watched, progressSeconds: positionSeconds),
    );

/// A series whose seasons and episodes the test scripts, with the Next Up
/// capability a Mydia instance has.
class _SeriesSource extends ScriptedDetailSource implements NextUp {
  _SeriesSource({required this.episodes, this.nextUpEpisode})
      : super(
          detailOf: (ref) => ref.kind == ItemKind.episode
              ? ItemDetail(
                  summary: ItemSummary(
                    ref: ref,
                    title: 'Episode',
                    index: 2,
                    parentIndex: 1,
                    defaultVersionId: '${ref.externalId}-sd',
                  ),
                  versions: [
                    MediaVersion(id: '${ref.externalId}-sd', height: 480),
                    MediaVersion(id: '${ref.externalId}-hd', height: 1080),
                  ],
                )
              : ItemDetail(
                  summary: ItemSummary(
                    ref: ref,
                    title: 'Harbor Lights',
                    year: 2022,
                  ),
                  overview: 'A coastal mystery series.',
                  genres: const ['Mystery', 'Drama'],
                  contentRating: 'TV-14',
                  rating: 7.9,
                  cast: const [Person(name: 'Del Osei', role: 'Det. Osei')],
                ),
        ) {
    childrenOf = (parent) => switch (parent.kind) {
          ItemKind.show => [
              for (final n in episodes.keys)
                ItemSummary(ref: _seasonRef(n), title: 'Season $n', index: n),
            ],
          _ => episodes[int.parse(parent.externalId.substring(3))] ?? const [],
        };
  }

  final Map<int, List<ItemSummary>> episodes;
  final ItemSummary? nextUpEpisode;

  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.nextUp};

  @override
  Future<ItemSummary?> nextUp(ItemRef show) async => nextUpEpisode;
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  Map<int, List<ItemSummary>>? episodes,
  ItemSummary? nextUp,
  bool defaultNextUp = true,
  List<String>? pushedRoutes,
  Size size = const Size(800, 600),
  int? initialSeason,
}) {
  final byseason = episodes ??
      {
        1: [_episode(1, watched: true), _episode(2), _episode(3)],
      };
  final source = _SeriesSource(
    episodes: byseason,
    nextUpEpisode: nextUp ?? (defaultNextUp ? _episode(2) : null),
  );
  return pumpDetailScreen(
    tester,
    ShowDetailScreen.target(
      target: const SourceTarget(_show),
      initialSeason: initialSeason,
    ),
    [source],
    size: size,
    routes: [
      GoRoute(
        path: '/s/:sourceId/player/:itemId',
        builder: (context, state) {
          pushedRoutes?.add(state.uri.toString());
          return const Scaffold(body: SizedBox.shrink());
        },
      ),
    ],
  );
}

void main() {
  testWidgets('the hero offers every version of its episode', (tester) async {
    await _pumpScreen(tester, size: const Size(1280, 900));
    await tester.pumpAndSettle();
    final hero = find.byType(HeroPlayControl);
    expect(tester.widget<HeroPlayControl>(hero).files, hasLength(2));
    // The best version is picked after real device detection, which the
    // fake clock cannot advance: poll in real time, then pump the result.
    for (var i = 0; i < 50; i++) {
      if (find
          .descendant(of: hero, matching: find.text('1080p'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(
      find.descendant(of: hero, matching: find.text('1080p')),
      findsWidgets,
    );
  });

  testWidgets('hero defaults to the next-unwatched episode', (tester) async {
    await _pumpScreen(tester);

    expect(find.textContaining('E2'), findsWidgets);
    expect(find.byType(CastRail), findsOneWidget);
  });

  testWidgets('tapping a different episode re-targets the hero',
      (tester) async {
    await _pumpScreen(tester);

    // The episode rail sits below the redesigned hero/cast/similar sections,
    // past the default test viewport: scroll it into view before tapping.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('ep-1-3')),
      200,
      // The screen has multiple Scrollables (cast rail, season chips, episode
      // rail are all horizontal ListViews); the first one found in the tree
      // is the outer vertical CustomScrollView, which is what needs to move.
      scrollable: find.byType(Scrollable).first,
    );
    // scrollUntilVisible stops as soon as the tile exists in the tree, which
    // the sliver cache extent makes true while it is still below the viewport.
    // ensureVisible actually brings it on screen so the tap lands.
    await tester.ensureVisible(find.byKey(const ValueKey('ep-1-3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ep-1-3')));
    await tester.pumpAndSettle();

    expect(find.textContaining('E3'), findsWidgets);
  });

  testWidgets('fully-watched show (no next up) still renders the hero',
      (tester) async {
    // With every episode watched there is no next up, so the hero's
    // default-selection seed never fires and the selected episode id stays
    // null. The hero must fall back to the season's first episode rather than
    // spinning forever.
    await _pumpScreen(
      tester,
      defaultNextUp: false,
      episodes: {
        1: [
          _episode(1, watched: true),
          _episode(2, watched: true),
          _episode(3, watched: true),
        ],
      },
    );

    expect(find.text('Play'), findsOneWidget);
    expect(find.byType(DetailActionRow), findsOneWidget);
    expect(find.text('S1 · E1'), findsOneWidget);
  });

  final twoSeasons = {
    1: [_episode(1, watched: true), _episode(2), _episode(3)],
    2: [_episode(1, season: 2), _episode(2, season: 2)],
  };

  testWidgets('switching seasons re-targets the hero at the new season',
      (tester) async {
    // The selected episode id still points at a season 1 episode after the
    // switch, so it matches nothing in season 2's list: the hero has to fall
    // back to season 2's first episode instead of spinning forever.
    await _pumpScreen(
      tester,
      // A tall viewport keeps the hero and the season chips on screen at the
      // same time, so the assertion sees the hero the tap re-targeted rather
      // than an unbuilt sliver scrolled out of view.
      size: const Size(1000, 2200),
      episodes: twoSeasons,
    );

    await tester.tap(find.text('Season 2'));
    await tester.pumpAndSettle();

    expect(find.byType(DetailActionRow), findsOneWidget);
    expect(find.text('S2 · E1'), findsOneWidget);
  });

  testWidgets('initialSeason seeds once and a later season tap sticks',
      (tester) async {
    await _pumpScreen(
      tester,
      size: const Size(1000, 2200),
      initialSeason: 2,
      episodes: twoSeasons,
    );
    await tester.pumpAndSettle();

    // Opened on season 2, not on next up (season 1).
    expect(find.text('S2 · E1'), findsOneWidget);

    await tester.tap(find.text('Season 1'));
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pump();

    expect(find.text('S1 · E1'), findsOneWidget);
    expect(find.text('S2 · E1'), findsNothing);
  });

  testWidgets('hero shows the release year under the title', (tester) async {
    await _pumpScreen(tester);

    expect(find.text('2022'), findsOneWidget);
  });

  testWidgets('content rating and genres render once, in the hero tag row',
      (tester) async {
    // The tall viewport builds the lower metadata section too, so a
    // reintroduced duplicate down there would be found, not silently
    // scrolled out of the tree.
    await _pumpScreen(tester, size: const Size(1000, 2200));

    expect(find.text('TV-14'), findsOneWidget);
    expect(find.text('Mystery'), findsOneWidget);
    expect(find.text('Drama'), findsOneWidget);
  });

  testWidgets('Play passes a resume position for a part-watched episode',
      (tester) async {
    final pushed = <String>[];
    final partWatched = _episode(2, positionSeconds: 900);

    await _pumpScreen(
      tester,
      size: const Size(1000, 1200),
      nextUp: partWatched,
      episodes: {
        1: [_episode(1, watched: true), partWatched, _episode(3)],
      },
      pushedRoutes: pushed,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PlayButton));
    await tester.pumpAndSettle();

    expect(pushed, hasLength(1));
    expect(pushed.single, contains('/player/ep-1-2'));
    expect(pushed.single, contains('resume=900'));
  });

  testWidgets('Play omits resume for an already-watched episode',
      (tester) async {
    final pushed = <String>[];
    final watched = _episode(2, watched: true);

    await _pumpScreen(
      tester,
      size: const Size(1000, 1200),
      nextUp: watched,
      episodes: {
        1: [_episode(1, watched: true), watched, _episode(3)],
      },
      pushedRoutes: pushed,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PlayButton));
    await tester.pumpAndSettle();

    expect(pushed, hasLength(1));
    expect(pushed.single, isNot(contains('resume=')));
  });

  testWidgets('hero play control sits flush against the overlay right edge',
      (tester) async {
    await _pumpScreen(tester, size: const Size(1000, 1200));
    await tester.pumpAndSettle();

    // The content overlay is inset 20 from the right of the 1000px surface.
    // The control itself, not its last child: the fixture's episodes carry
    // several versions, so a quality dropdown follows the PlayButton.
    expect(
      tester.getRect(find.byType(HeroPlayControl)).right,
      closeTo(980, 0.5),
    );
  });

  testWidgets('hero play control lives in the hero, not the body',
      (tester) async {
    await _pumpScreen(tester, size: const Size(1000, 1200));
    await tester.pumpAndSettle();

    // 380 is the hero SliverAppBar's expandedHeight, set in
    // _buildHeroSection. Unscrolled, anything below that line is in the
    // body, where _buildActionColumn lives. This is what distinguishes
    // "moved to the title row" from "merely re-aligned in the action column".
    final play = tester.getRect(find.byType(PlayButton));
    final actions = tester.getRect(find.byType(DetailActionRow));
    expect(play.bottom, lessThan(380));
    expect(play.bottom, lessThan(actions.top));

    // Wide layout: the row shrink-wraps to one 64px slot per action, flush
    // with the body's 20px inset, instead of squeezing into a fixed column.
    final slots = find.descendant(
      of: find.byType(DetailActionRow),
      matching: find.byType(InkWell),
    );
    expect(actions.left, closeTo(20, 0.5));
    expect(actions.width, 64.0 * tester.widgetList(slots).length);
  });

  testWidgets('hero overlay does not overflow at phone width', (tester) async {
    // The show hero is the wider of the two detail heroes: it carries the
    // episode context pill alongside the title and Play control, so it is
    // the most likely to overflow a narrow viewport. A layout overflow
    // surfaces as a FlutterError, which fails the test even without an
    // explicit assertion for it.
    await _pumpScreen(tester, size: const Size(400, 1200));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets(
      'tapping a rail card selects the episode without starting playback',
      (tester) async {
    final pushed = <String>[];

    await _pumpScreen(
      tester,
      size: const Size(1000, 2200),
      pushedRoutes: pushed,
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byType(EpisodeRailCard).last,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();

    expect(pushed, isEmpty);
    final cards = tester
        .widgetList<EpisodeRailCard>(find.byType(EpisodeRailCard))
        .toList();
    expect(cards.last.selected, isTrue);
  });

  testWidgets('tapping a rail card carries the viewport back to the hero',
      (tester) async {
    await _pumpScreen(
      tester,
      // Phone-shaped, so the rail sits well below the fold and there is real
      // scroll extent for _revealHero to travel back across. 1200px tall is
      // the minimum height where the episode sliver is built but still below
      // the fold; at 800px the lazy sliver never mounts and at 1400px+ the
      // rail is already visible without scrolling.
      size: const Size(400, 1200),
    );
    await tester.pumpAndSettle();

    final verticalScrollable = find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first;

    await tester.scrollUntilVisible(
      find.byType(EpisodeRailCard).first,
      300,
      scrollable: verticalScrollable,
    );
    await tester.pumpAndSettle();

    final position = tester.state<ScrollableState>(verticalScrollable).position;
    expect(
      position.pixels,
      greaterThan(position.minScrollExtent),
      reason: 'the rail must start below the fold or this test is vacuous',
    );

    await tester.tap(find.byType(EpisodeRailCard).first);
    await tester.pumpAndSettle();

    expect(position.pixels, position.minScrollExtent);
  });
}
