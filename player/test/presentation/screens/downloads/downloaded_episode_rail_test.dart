import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/playback/playback_progress_providers.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/presentation/screens/downloads/widgets/downloaded_episode_card.dart';
import 'package:player/presentation/screens/downloads/widgets/downloaded_episode_rail.dart';

import '../../../test_utils/mock_network_images.dart';

DownloadedMedia _media(int episodeNumber) {
  return DownloadedMedia(
    id: 'd$episodeNumber',
    mediaId: 'ep-$episodeNumber',
    title: 'Episode $episodeNumber',
    quality: '1080p',
    filePath: '/tmp/$episodeNumber.mp4',
    fileSize: 1024,
    mediaType: 'episode',
    downloadedAt: DateTime(2026, 1, 1),
    seasonNumber: 1,
    episodeNumber: episodeNumber,
    showId: 'show-1',
    thumbnailUrl: 'https://example.test/$episodeNumber.jpg',
  );
}

Future<void> _pump(WidgetTester tester, int count) async {
  await mockNetworkImages(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackProgressStoreProvider
              .overrideWith((ref) async => InMemoryPlaybackProgressStore()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: DownloadedEpisodeRail(
              episodes: List.generate(count, (i) => _media(i + 1)),
              showId: 'show-1',
              seasonNumber: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  });
}

void main() {
  testWidgets('renders one card per episode', (tester) async {
    await _pump(tester, 3);

    expect(find.byType(DownloadedEpisodeCard), findsNWidgets(3));
    expect(find.byKey(const ValueKey('ep-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('ep-3')), findsOneWidget);
  });

  testWidgets('renders nothing when the season has no downloads',
      (tester) async {
    await _pump(tester, 0);

    expect(find.byType(DownloadedEpisodeCard), findsNothing);
  });

  testWidgets('carries a season-scoped right fade key', (tester) async {
    await _pump(tester, 12);

    expect(
      find.byKey(const ValueKey('downloaded-rail-1-right-fade')),
      findsOneWidget,
    );
  });
}
