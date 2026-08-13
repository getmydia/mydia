import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/domain/models/episode.dart';
import 'package:player/domain/models/progress.dart';
import 'package:player/presentation/widgets/episode_rail_card.dart';
import 'package:player/presentation/widgets/watch_indicator.dart';

import '../../test_utils/hover_affordance.dart';
import '../../test_utils/mock_network_images.dart';
import '../../test_utils/poster_contract.dart';

Episode _episode({
  bool hasFile = true,
  Progress? progress,
  String? thumbnailUrl = 'https://example.test/thumb.jpg',
  String? overview,
}) {
  return Episode(
    id: 'ep-1',
    seasonNumber: 1,
    episodeNumber: 1,
    title: 'Pilot',
    overview: overview,
    monitored: true,
    hasFile: hasFile,
    thumbnailUrl: thumbnailUrl,
    progress: progress,
  );
}

Future<void> _pump(
  WidgetTester tester,
  Episode episode, {
  VoidCallback? onTap,
  bool selected = false,
}) async {
  await mockNetworkImages(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isMediaDownloadedProvider(episode.id).overrideWith((ref) => false),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: EpisodeRailCard(
              episode: episode,
              showTitle: 'Test Show',
              showId: 'show-1',
              onTap: onTap,
              selected: selected,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  });
}

void main() {
  testWidgets(
      'AE1: fully-watched episode shows a checkmark and no progress bar',
      (tester) async {
    await _pump(
      tester,
      _episode(
        progress: const Progress(
          positionSeconds: 0,
          percentage: 0,
          watched: true,
        ),
      ),
    );

    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byType(FractionallySizedBox), findsNothing);
  });

  testWidgets('AE2: in-progress episode shows a ~40% bar and no checkmark',
      (tester) async {
    await _pump(
      tester,
      _episode(
        progress: const Progress(
          positionSeconds: 0,
          percentage: 40,
          watched: false,
        ),
      ),
    );

    expect(find.byIcon(Icons.check_rounded), findsNothing);
    final bar = tester.widget<FractionallySizedBox>(
      find.byType(FractionallySizedBox),
    );
    expect(bar.widthFactor, closeTo(0.4, 0.001));
  });

  testWidgets(
      'null progress renders neither bar nor checkmark and does not throw',
      (tester) async {
    await _pump(tester, _episode(progress: null));

    expect(find.byIcon(Icons.check_rounded), findsNothing);
    expect(find.byType(FractionallySizedBox), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'AE3: a no-file episode is dimmed/unavailable and does not navigate',
      (tester) async {
    var tapped = false;
    await _pump(
      tester,
      _episode(hasFile: false),
      onTap: () => tapped = true,
    );

    // Visually distinct: dimmed via Opacity + an "unavailable" badge.
    expect(find.byType(Opacity), findsWidgets);
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);

    // Tapping the card must not invoke navigation (no onTap wired for no-file).
    await tester.tap(find.byType(EpisodeRailCard));
    await tester.pump();
    expect(tapped, isFalse);
  });

  testWidgets('renders episode code and title but never the overview',
      (tester) async {
    await _pump(
      tester,
      _episode(overview: 'A secret synopsis that should not appear.'),
    );

    expect(find.text('S01E01'), findsOneWidget);
    expect(find.text('Pilot'), findsOneWidget);
    expect(
      find.text('A secret synopsis that should not appear.'),
      findsNothing,
    );
  });

  testWidgets('tapping a playable card invokes onTap once', (tester) async {
    var taps = 0;
    await _pump(tester, _episode(), onTap: () => taps++);

    await tester.tap(find.byType(EpisodeRailCard));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('shows the placeholder when the thumbnail URL is null',
      (tester) async {
    await _pump(tester, _episode(thumbnailUrl: null));

    expect(find.byIcon(Icons.tv_rounded), findsOneWidget);
  });

  testWidgets('selected draws a highlighted border, unselected does not',
      (tester) async {
    await _pump(tester, _episode(), selected: true);

    final container = tester.widget<Container>(
      find.byKey(const ValueKey('episode-card-border')),
    );
    final decoration = container.decoration as BoxDecoration;
    final border = decoration.border as Border;
    expect(border.top.color, AppColors.primary);
    expect(border.top.width, 2);

    await _pump(tester, _episode());

    final unselectedContainer = tester.widget<Container>(
      find.byKey(const ValueKey('episode-card-border')),
    );
    final unselectedDecoration =
        unselectedContainer.decoration as BoxDecoration;
    final unselectedBorder = unselectedDecoration.border as Border;
    expect(unselectedBorder.top.color, Colors.transparent);
    expect(unselectedBorder.top.width, 2);
  });

  testWidgets(
      'offers no play glyph at rest or on hover, because tapping a rail card '
      'selects the episode into the hero rather than playing it',
      (tester) async {
    await _pump(tester, _episode());
    await tester.pumpAndSettle();

    expect(findPlayGlyph(), findsNothing);

    await hoverOver(tester, find.byType(EpisodeRailCard));

    expect(findPlayGlyph(), findsNothing);
  });

  testWidgets('hover previews the selection ring on an unselected card',
      (tester) async {
    await _pump(tester, _episode());
    await tester.pumpAndSettle();

    // Keyed rather than found by type: MaterialApp's own route machinery
    // contributes AnimatedOpacity widgets, so a bare byType finder would be
    // reading whichever one happened to come first in tree order.
    final ring = find.byKey(EpisodeRailCard.selectionPreviewKey);

    expect(tester.widget<AnimatedOpacity>(ring).opacity, 0.0);

    await hoverOver(tester, find.byType(EpisodeRailCard));

    expect(tester.widget<AnimatedOpacity>(ring).opacity, 1.0);
  });

  testWidgets('an already-selected card previews nothing on hover',
      (tester) async {
    await _pump(tester, _episode(), selected: true);
    await tester.pumpAndSettle();

    await hoverOver(tester, find.byType(EpisodeRailCard));

    // The card already draws its real ring; a preview of it would be noise.
    expect(find.byKey(EpisodeRailCard.selectionPreviewKey), findsNothing);
  });

  group('EpisodeRailCard watch state', () {
    testWidgets('draws an unwatched dot on an episode never played',
        (tester) async {
      await _pump(tester, _episode(progress: null));

      expect(find.byKey(WatchIndicator.dotKey), findsOneWidget);
    });

    testWidgets('draws no dot once the episode is watched', (tester) async {
      await _pump(
        tester,
        _episode(
          progress: const Progress(
            positionSeconds: 100,
            durationSeconds: 100,
            percentage: 100,
            watched: true,
          ),
        ),
      );

      expect(find.byKey(WatchIndicator.dotKey), findsNothing);
    });

    testWidgets('draws no dot while the episode is part-played',
        (tester) async {
      await _pump(
        tester,
        _episode(
          progress: const Progress(
            positionSeconds: 40,
            durationSeconds: 100,
            percentage: 40,
            watched: false,
          ),
        ),
      );

      expect(find.byKey(WatchIndicator.dotKey), findsNothing);
    });
  });
}
