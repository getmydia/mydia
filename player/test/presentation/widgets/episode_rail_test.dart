import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/domain/models/episode.dart';
import 'package:player/presentation/widgets/episode_rail.dart';
import 'package:player/presentation/widgets/episode_rail_card.dart';

import '../../test_utils/mock_network_images.dart';

Episode _episode(int n, {bool hasFile = true}) {
  return Episode(
    id: 'ep-$n',
    seasonNumber: 1,
    episodeNumber: n,
    title: 'Episode $n',
    monitored: true,
    hasFile: hasFile,
    thumbnailUrl: 'https://example.test/$n.jpg',
  );
}

List<Episode> _episodes(int count, {bool hasFile = true}) =>
    List.generate(count, (i) => _episode(i, hasFile: hasFile));

Future<void> _pump(
  WidgetTester tester,
  List<Episode> episodes, {
  String? showId = 'show-1',
  ValueChanged<Episode>? onEpisodeTap,
}) async {
  await mockNetworkImages(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          for (final e in episodes)
            isMediaDownloadedProvider(e.id).overrideWith((ref) => false),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: EpisodeRail(
              episodes: episodes,
              showTitle: 'Test Show',
              showId: showId,
              onEpisodeTap: onEpisodeTap,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  });
}

void main() {
  testWidgets('renders one card per episode, each with a stable id key',
      (tester) async {
    await _pump(tester, _episodes(3));

    expect(find.byType(EpisodeRailCard), findsNWidgets(3));
    expect(find.byKey(const ValueKey('ep-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('ep-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('ep-2')), findsOneWidget);
  });

  testWidgets('an empty episode list collapses to nothing', (tester) async {
    await _pump(tester, const []);

    expect(find.byType(EpisodeRailCard), findsNothing);
    expect(find.byType(SizedBox), findsOneWidget); // the SizedBox.shrink()
  });

  testWidgets('shows the right fade and hides the left fade at offset 0',
      (tester) async {
    await _pump(tester, _episodes(20, hasFile: false), showId: null);

    // At rest (offset 0) only the right-edge fade is shown.
    expect(
      find.byKey(const ValueKey('episode-rail-right-fade')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('episode-rail-left-fade')),
      findsNothing,
    );
  });

  testWidgets('tapping a card forwards the correct episode', (tester) async {
    Episode? tapped;
    await _pump(tester, _episodes(3), onEpisodeTap: (e) => tapped = e);

    await tester.tap(find.byKey(const ValueKey('ep-1')));
    await tester.pump();

    expect(tapped, isNotNull);
    expect(tapped!.id, 'ep-1');
  });
}
