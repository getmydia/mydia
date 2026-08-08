import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/playback/playback_progress_providers.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/presentation/screens/downloads/series_downloads_screen.dart';
import 'package:player/presentation/screens/downloads/widgets/download_queue_row.dart';
import 'package:player/presentation/screens/downloads/widgets/downloaded_episode_rail.dart';

import '../../../test_utils/mock_network_images.dart';

DownloadedMedia _downloaded(int season, int episode) {
  return DownloadedMedia(
    id: 'd-$season-$episode',
    mediaId: 'ep-$season-$episode',
    title: 'Episode $episode',
    quality: '1080p',
    filePath: '/tmp/$season-$episode.mp4',
    fileSize: 1024,
    mediaType: 'episode',
    downloadedAt: DateTime(2026, 1, 1),
    seasonNumber: season,
    episodeNumber: episode,
    showId: 'show-1',
    thumbnailUrl: 'https://example.test/$season-$episode.jpg',
  );
}

DownloadTask _queued(int season, int episode) {
  return DownloadTask(
    id: 't-$season-$episode',
    mediaId: 'ep-$season-$episode',
    title: 'Episode $episode',
    quality: '1080p',
    progress: 0.25,
    status: 'downloading',
    mediaType: 'episode',
    fileSize: 2048,
    createdAt: DateTime(2026, 1, 1),
    seasonNumber: season,
    episodeNumber: episode,
    showId: 'show-1',
  );
}

Future<void> _pump(
  WidgetTester tester, {
  List<DownloadedMedia> downloaded = const [],
  List<DownloadTask> queue = const [],
}) async {
  // Tall enough that multi-season rails stay in the buildable viewport —
  // SliverList does not build off-screen children.
  await tester.binding.setSurfaceSize(const Size(800, 2000));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  await mockNetworkImages(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadedMediaProvider
              .overrideWith((ref) => Stream.value(downloaded)),
          downloadQueueProvider.overrideWith((ref) => Stream.value(queue)),
          downloadSpeedInfoProvider.overrideWith((ref) => Stream.value({})),
          playbackProgressStoreProvider
              .overrideWith((ref) async => InMemoryPlaybackProgressStore()),
        ],
        child: const MaterialApp(
          home: SeriesDownloadsScreen(
            showId: 'show-1',
            showTitle: 'Test Show',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  });
}

void main() {
  testWidgets('renders one rail per season', (tester) async {
    await _pump(tester, downloaded: [
      _downloaded(1, 1),
      _downloaded(1, 2),
      _downloaded(2, 1),
    ]);

    expect(find.byType(DownloadedEpisodeRail), findsNWidgets(2));
  });

  testWidgets('season headers carry the episode count', (tester) async {
    await _pump(tester, downloaded: [_downloaded(1, 1), _downloaded(1, 2)]);

    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('(2 episodes)'), findsOneWidget);
  });

  testWidgets('renders a season header even for a single season',
      (tester) async {
    await _pump(tester, downloaded: [_downloaded(1, 1)]);

    expect(find.text('Season 1'), findsOneWidget);
    expect(find.text('(1 episode)'), findsOneWidget);
  });

  testWidgets('labels season zero as Specials', (tester) async {
    await _pump(tester, downloaded: [_downloaded(0, 1)]);

    expect(find.text('Specials'), findsOneWidget);
  });

  testWidgets('renders a queue row per in-progress task', (tester) async {
    await _pump(tester, queue: [_queued(1, 3), _queued(1, 4)]);

    expect(find.byType(DownloadQueueRow), findsNWidgets(2));
  });

  testWidgets('shows the empty state when there is nothing', (tester) async {
    await _pump(tester);

    expect(find.text('No episodes found'), findsOneWidget);
  });
}
