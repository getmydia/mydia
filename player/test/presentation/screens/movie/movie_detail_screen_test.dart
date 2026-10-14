import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/detail/detail_sections.dart';
import 'package:player/presentation/screens/movie/movie_detail_screen.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/cast_rail.dart';
import 'package:player/presentation/widgets/nav/mobile_drawer.dart';
import 'package:player/presentation/widgets/detail_hero_app_bar.dart';
import 'package:player/presentation/widgets/detail_action_row.dart';
import 'package:player/presentation/widgets/movie_watched_controls.dart';
import 'package:player/presentation/widgets/primary_play_button.dart';

import '../detail/detail_harness.dart';
import '../sources/fake_media_source.dart';

const _ref =
    ItemRef(sourceId: fakeSourceId, kind: ItemKind.movie, externalId: 'm-1');

/// The fixture supplies no versions, so the hero's play control renders no
/// resolution label and PrimaryPlayButton is its only child.
Future<void> _pumpScreen(
  WidgetTester tester,
  Size size, {
  UserState userState = const UserState(),
}) {
  final source = ScriptedDetailSource(
    detailOf: (ref) => ItemDetail(
      summary: ItemSummary(
        ref: ref,
        title: 'Meridian Drift',
        year: 2024,
        durationSeconds: 8760,
        userState: userState,
      ),
      overview: 'A drifting research platform runs out of air.',
      genres: const ['Sci-Fi', 'Adventure'],
      contentRating: 'PG-13',
      rating: 8.1,
      cast: const [Person(name: 'Ana Bergstrom', role: 'Kira Solt')],
    ),
  );
  return pumpDetailScreen(
    tester,
    const MovieDetailScreen.target(target: SourceTarget(_ref)),
    [source],
    size: size,
  );
}

void main() {
  menuButtonTests();

  testWidgets('wide layout shows the action column beside the tag column',
      (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));

    expect(find.text('Play'), findsOneWidget);
    expect(find.byType(DetailActionRow), findsOneWidget);
    expect(find.byType(CastRail), findsOneWidget);
  });

  testWidgets('overview is its own section and not repeated in the tag column',
      (tester) async {
    await _pumpScreen(tester, const Size(1000, 1400));

    expect(find.byType(DetailOverview), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.byType(CastRail), findsOneWidget);
    expect(find.text('Ana Bergstrom'), findsOneWidget);
    const overview = 'A drifting research platform runs out of air.';
    expect(find.text(overview), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(DetailTagColumn),
        matching: find.text(overview),
      ),
      findsNothing,
    );
    // Same order as the show page: cast first, overview below it.
    expect(
      tester.getTopLeft(find.byType(DetailOverview)).dy,
      greaterThan(tester.getBottomLeft(find.byType(CastRail)).dy),
    );
  });

  testWidgets('narrow layout still renders the action column and tags',
      (tester) async {
    await _pumpScreen(tester, const Size(400, 900));

    expect(find.text('Play'), findsOneWidget);
    expect(find.byType(DetailActionRow), findsOneWidget);
  });

  testWidgets('hero shows the release year under the title', (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));

    expect(find.text('2024'), findsOneWidget);
  });

  testWidgets('rating renders under the overview, not in the tag row',
      (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));

    expect(find.text('8.1'), findsOneWidget);
  });

  testWidgets('shows the watched line when the movie is marked watched',
      (tester) async {
    await _pumpScreen(
      tester,
      const Size(1000, 900),
      userState: const UserState(watched: true),
    );

    expect(find.byType(MovieWatchedLine), findsOneWidget);
  });

  testWidgets('shows a resume progress bar when there is resumable progress',
      (tester) async {
    await _pumpScreen(
      tester,
      const Size(1000, 900),
      userState: const UserState(progressSeconds: 4200),
    );

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('hero play control sits flush against the overlay right edge',
      (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));

    // The content overlay is inset 20 from the right of the 1000px surface.
    expect(tester.getRect(find.byType(PrimaryPlayButton)).right,
        closeTo(980, 0.5));
  });

  testWidgets('hero play control lives in the hero, not the body',
      (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));

    // 380 is the hero SliverAppBar's expandedHeight, set in
    // _buildHeroSection. Unscrolled, anything below that line is in the
    // body, where _buildActionColumn lives.
    final play = tester.getRect(find.byType(PrimaryPlayButton));
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
}

/// The movie page inside a Scaffold keyed like the phone shell's, so the
/// drawer exists the way it does there.
Future<void> _pumpInShell(WidgetTester tester, Size size) {
  // Logical pixels, as the shell's breakpoint reads them.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final source = ScriptedDetailSource(
    detailOf: (ref) => ItemDetail(
      summary: ItemSummary(ref: ref, title: 'Meridian Drift'),
    ),
  );
  return pumpDetailScreen(
    tester,
    Scaffold(
      key: AppShell.scaffoldKey,
      drawer: MobileDrawer(location: '/', onNavigate: (_) {}),
      body: const MovieDetailScreen.target(target: SourceTarget(_ref)),
    ),
    [source],
    size: size,
  );
}

void menuButtonTests() {
  testWidgets('a phone gets a Menu button that opens the shell drawer',
      (tester) async {
    await _pumpInShell(tester, const Size(400, 900));

    final menu = find.byKey(const Key('source-open-drawer'));
    expect(menu, findsOneWidget);
    expect(find.byTooltip('Menu'), findsOneWidget);
    expect(find.byType(MobileDrawer), findsNothing);

    await tester.tap(menu);
    await tester.pumpAndSettle();

    expect(find.byType(MobileDrawer), findsOneWidget);
  });

  testWidgets('the Menu button is left of the back button, both leading',
      (tester) async {
    await _pumpInShell(tester, const Size(400, 900));

    final menu = tester.getRect(find.byKey(const Key('source-open-drawer')));
    final back = tester.getRect(find.byType(DetailHeroBackButton));
    expect(menu.right, lessThanOrEqualTo(back.left));
    // Both sit at the leading edge: two 48 px buttons after the 8 px gutter.
    expect(menu.left, lessThan(16));
    expect(back.right, lessThan(110));
    expect(menu.size, back.size);
    expect(menu.center.dy, closeTo(back.center.dy, 0.5));
  });

  testWidgets('a wide window has no Menu button', (tester) async {
    await _pumpInShell(tester, const Size(1280, 900));

    expect(find.byKey(const Key('source-open-drawer')), findsNothing);
  });

  testWidgets('outside the shell there is no drawer, so no Menu button',
      (tester) async {
    await _pumpScreen(tester, const Size(400, 900));

    expect(find.byKey(const Key('source-open-drawer')), findsNothing);
  });
}
