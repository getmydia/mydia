import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/playback/playback_progress_providers.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/presentation/screens/downloads/widgets/downloaded_episode_card.dart';
import 'package:player/presentation/widgets/quality_badge.dart';

import '../../../test_utils/mock_network_images.dart';

DownloadedMedia _media({
  String quality = '1080p',
  String? thumbnailUrl = 'https://example.test/ep.jpg',
}) {
  return DownloadedMedia(
    id: 'd1',
    mediaId: 'ep-1',
    title: 'Pilot',
    quality: quality,
    filePath: '/tmp/ep.mp4',
    fileSize: 1610612736, // exactly 1.5 GiB -> "1.50 GB"
    mediaType: 'episode',
    downloadedAt: DateTime(2026, 1, 1),
    seasonNumber: 1,
    episodeNumber: 1,
    showId: 'show-1',
    thumbnailUrl: thumbnailUrl,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required DownloadedMedia media,
  LocalPlaybackProgress? progress,
}) async {
  final store = InMemoryPlaybackProgressStore();
  if (progress != null) {
    await store.save(progress);
  }

  await mockNetworkImages(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackProgressStoreProvider.overrideWith((ref) async => store),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: DownloadedEpisodeCard(media: media, showId: 'show-1'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  });
}

void main() {
  testWidgets('renders the episode code, title and file size', (tester) async {
    await _pump(tester, media: _media());

    expect(find.text('S01E01'), findsOneWidget);
    expect(find.text('Pilot'), findsOneWidget);
    expect(find.text('1.50 GB'), findsOneWidget);
  });

  testWidgets('renders the quality badge when quality is set', (tester) async {
    await _pump(tester, media: _media());

    expect(find.byType(QualityBadge), findsOneWidget);
  });

  testWidgets('omits the quality badge when quality is empty', (tester) async {
    await _pump(tester, media: _media(quality: ''));

    expect(find.byType(QualityBadge), findsNothing);
  });

  testWidgets('omits the resume bar when there is no stored progress',
      (tester) async {
    await _pump(tester, media: _media());

    expect(
      find.byKey(const ValueKey('downloaded-episode-resume-bar')),
      findsNothing,
    );
  });

  testWidgets('renders the resume bar when progress is stored', (tester) async {
    await _pump(
      tester,
      media: _media(),
      progress: LocalPlaybackProgress(
        mediaId: 'ep-1',
        mediaType: 'episode',
        positionSeconds: 300,
        durationSeconds: 1200,
        updatedAt: DateTime(2026, 1, 1),
      ),
    );

    expect(
      find.byKey(const ValueKey('downloaded-episode-resume-bar')),
      findsOneWidget,
    );
  });

  testWidgets('the action menu offers play and delete', (tester) async {
    await _pump(tester, media: _media());

    await tester.tap(find.byKey(const ValueKey('downloaded-episode-menu')));
    await tester.pumpAndSettle();

    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
  });
}
