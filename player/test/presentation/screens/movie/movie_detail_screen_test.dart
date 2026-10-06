import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/movie/movie_detail_screen.dart';
import 'package:player/presentation/widgets/cast_rail.dart';
import 'package:player/presentation/widgets/detail_action_row.dart';
import 'package:player/presentation/widgets/movie_watched_controls.dart';
import 'package:player/presentation/widgets/play_button.dart';

import '../detail/detail_harness.dart';
import '../sources/fake_media_source.dart';

const _ref =
    ItemRef(sourceId: fakeSourceId, kind: ItemKind.movie, externalId: 'm-1');

/// The fixture supplies no versions, so the hero's play control renders no
/// resolution label and PlayButton is its only child.
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
  testWidgets('wide layout shows the action column beside the tag column',
      (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));

    expect(find.text('Play'), findsOneWidget);
    expect(find.byType(DetailActionRow), findsOneWidget);
    expect(find.byType(CastRail), findsOneWidget);
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
    expect(tester.getRect(find.byType(PlayButton)).right, closeTo(980, 0.5));
  });

  testWidgets('hero play control lives in the hero, not the body',
      (tester) async {
    await _pumpScreen(tester, const Size(1000, 900));

    // 380 is the hero SliverAppBar's expandedHeight, set in
    // _buildHeroSection. Unscrolled, anything below that line is in the
    // body, where _buildActionColumn lives.
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
}
