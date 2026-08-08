import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/presentation/screens/downloads/widgets/download_queue_row.dart';

DownloadTask _task({
  double progress = 0.5,
  bool isProgressive = false,
  double transcodeProgress = 0.0,
  double downloadProgress = 0.0,
  int? fileSize = 3221225472, // exactly 3 GiB -> "3.00 GB"
  int? downloadedBytes = 1610612736, // exactly 1.5 GiB -> "1.50 GB"
}) {
  return DownloadTask(
    id: 't1',
    mediaId: 'ep-3',
    title: 'A Rather Long Episode Title',
    quality: '1080p',
    progress: progress,
    status: 'downloading',
    mediaType: 'episode',
    fileSize: fileSize,
    downloadedBytes: downloadedBytes,
    createdAt: DateTime(2026, 1, 1),
    isProgressive: isProgressive,
    transcodeProgress: transcodeProgress,
    downloadProgress: downloadProgress,
    seasonNumber: 1,
    episodeNumber: 3,
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required DownloadTask task,
  double bytesPerSecond = 0,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        downloadSpeedInfoProvider.overrideWith(
          (ref) => Stream.value({
            task.id: DownloadSpeedInfo(bytesPerSecond: bytesPerSecond),
          }),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(body: DownloadQueueRow(task: task)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the episode code and title', (tester) async {
    await _pump(tester, task: _task());

    expect(find.text('S01E03'), findsOneWidget);
    expect(find.text('A Rather Long Episode Title'), findsOneWidget);
  });

  testWidgets('renders percentage and byte progress', (tester) async {
    await _pump(tester, task: _task());

    expect(
      find.byKey(const ValueKey('download-queue-row-metrics')),
      findsOneWidget,
    );
    final metrics = tester.widget<Text>(
      find.byKey(const ValueKey('download-queue-row-metrics')),
    );
    expect(metrics.data, startsWith('50%'));
    expect(metrics.data, contains('1.50 GB / 3.00 GB'));
  });

  testWidgets('omits the speed segment when the rate is zero', (tester) async {
    await _pump(tester, task: _task());

    final metrics = tester.widget<Text>(
      find.byKey(const ValueKey('download-queue-row-metrics')),
    );
    expect(metrics.data, isNot(contains('/s')));
  });

  testWidgets('includes the speed segment when the rate is positive',
      (tester) async {
    await _pump(tester, task: _task(), bytesPerSecond: 4718592);

    final metrics = tester.widget<Text>(
      find.byKey(const ValueKey('download-queue-row-metrics')),
    );
    expect(metrics.data, contains('/s'));
  });

  testWidgets('uses combined progress for progressive tasks', (tester) async {
    await _pump(
      tester,
      task: _task(
        progress: 0.0,
        isProgressive: true,
        transcodeProgress: 1.0,
        downloadProgress: 0.5,
      ),
    );

    final bar = tester.widget<LinearProgressIndicator>(
      find.byKey(const ValueKey('download-queue-row-bar')),
    );
    // 1.0 * 0.3 + 0.5 * 0.7 = 0.65
    expect(bar.value, closeTo(0.65, 0.001));
  });

  testWidgets('cancel opens the confirmation dialog', (tester) async {
    await _pump(tester, task: _task());

    await tester.tap(find.byKey(const ValueKey('download-queue-row-cancel')));
    await tester.pumpAndSettle();

    expect(find.text('Cancel Download?'), findsOneWidget);
  });
}
