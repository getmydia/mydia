import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_job_providers.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/domain/models/download_option.dart';
import 'package:player/domain/models/episode.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/presentation/widgets/episode_download_button.dart';

Episode _episode({
  bool hasFile = true,
  List<MediaFile> files = const [],
}) {
  return Episode(
    id: 'ep-1',
    seasonNumber: 1,
    episodeNumber: 1,
    title: 'Pilot',
    monitored: true,
    hasFile: hasFile,
    files: files,
  );
}

void main() {
  // Each test constructs the button inline so it can vary the episode. The
  // quality dialog's options provider is overridden with a never-completing
  // future, keeping it in its loading state without touching the network.
  Future<void> pumpButton(
    WidgetTester tester, {
    required Episode episode,
    required bool downloaded,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isMediaDownloadedProvider(episode.id)
              .overrideWith((ref) => downloaded),
          downloadOptionsProvider('episode', episode.id).overrideWith(
              (ref) => Completer<DownloadOptionsResponse>().future),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: EpisodeDownloadButton(
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

  testWidgets('renders the download icon when not downloaded and has a file',
      (tester) async {
    await pumpButton(tester, episode: _episode(), downloaded: false);

    expect(find.byIcon(Icons.download_rounded), findsOneWidget);
    expect(find.byIcon(Icons.download_done_rounded), findsNothing);
  });

  testWidgets('renders the downloaded icon when the provider resolves true',
      (tester) async {
    await pumpButton(tester, episode: _episode(), downloaded: true);

    expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
    expect(find.byIcon(Icons.download_rounded), findsNothing);
  });

  testWidgets('renders nothing when the episode has no file', (tester) async {
    await pumpButton(
      tester,
      episode: _episode(hasFile: false),
      downloaded: false,
    );

    expect(find.byIcon(Icons.download_rounded), findsNothing);
    expect(find.byIcon(Icons.download_done_rounded), findsNothing);
  });

  testWidgets('tapping the button (not downloaded) opens the quality dialog',
      (tester) async {
    await pumpButton(
      tester,
      episode: _episode(
        files: const [MediaFile(id: 'f-1', directPlaySupported: true)],
      ),
      downloaded: false,
    );

    await tester.tap(find.byIcon(Icons.download_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // The dialog surface appears; full download execution is out of unit scope.
    expect(find.text('Download Quality'), findsOneWidget);
  });
}
