import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/domain/models/episode.dart';
import 'package:player/domain/models/progress.dart';
import 'package:player/presentation/widgets/episode_rail_card.dart';

Episode _episode({required bool? watched}) {
  return Episode(
    id: 'ep-1',
    seasonNumber: 1,
    episodeNumber: 1,
    title: 'Pilot',
    monitored: true,
    hasFile: true,
    // No thumbnail URL → placeholder, so the card needs no network mocking.
    progress: watched == null
        ? null
        : Progress(positionSeconds: 0, percentage: 0, watched: watched),
  );
}

Future<void> _pumpCard(WidgetTester tester, Episode episode) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // Keep the card hermetic — no real download-state lookups.
        isMediaDownloadedProvider(episode.id).overrideWith((ref) => false),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: EpisodeRailCard(
            episode: episode,
            showTitle: 'Test Show',
            showId: 'show-1',
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('overflow menu renders on the rail card', (tester) async {
    await _pumpCard(tester, _episode(watched: null));

    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
  });

  // The toggle item is the opposite of the card's current watched state.
  testWidgets('an unwatched episode offers "Mark watched"', (tester) async {
    await _pumpCard(tester, _episode(watched: null));

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Mark watched'), findsOneWidget);
    expect(find.text('Mark unwatched'), findsNothing);
    expect(find.text('Mark this and previous watched'), findsOneWidget);
  });

  testWidgets('a watched episode offers "Mark unwatched"', (tester) async {
    await _pumpCard(tester, _episode(watched: true));

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Mark unwatched'), findsOneWidget);
    expect(find.text('Mark watched'), findsNothing);
    expect(find.text('Mark this and previous watched'), findsOneWidget);
  });
}
