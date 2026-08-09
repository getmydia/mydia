import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_recovery.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/presentation/screens/downloads/downloads_screen.dart';

void main() {
  group('active download sheet', () {
    testWidgets('offers restart and cancel for a downloading task',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => activeDownloadSheetActions(
              context: context,
              status: 'downloading',
              onPause: () {},
              onResume: () {},
              onRestart: () {},
              onCancel: () {},
            ),
          ),
        ),
      ));

      expect(find.byKey(const Key('downloads-sheet-pause')), findsOneWidget);
      expect(find.byKey(const Key('downloads-sheet-restart')), findsOneWidget);
      expect(find.byKey(const Key('downloads-sheet-cancel')), findsOneWidget);
      expect(find.byKey(const Key('downloads-sheet-resume')), findsNothing);
    });

    testWidgets('offers resume rather than pause when paused', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => activeDownloadSheetActions(
              context: context,
              status: 'paused',
              onPause: () {},
              onResume: () {},
              onRestart: () {},
              onCancel: () {},
            ),
          ),
        ),
      ));

      expect(find.byKey(const Key('downloads-sheet-resume')), findsOneWidget);
      expect(find.byKey(const Key('downloads-sheet-pause')), findsNothing);
    });

    testWidgets('offers resume for interrupted and stalled', (tester) async {
      for (final status in ['interrupted', 'stalled']) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => activeDownloadSheetActions(
                context: context,
                status: status,
                onPause: () {},
                onResume: () {},
                onRestart: () {},
                onCancel: () {},
              ),
            ),
          ),
        ));
        expect(find.byKey(const Key('downloads-sheet-resume')), findsOneWidget,
            reason: 'status $status should offer resume');
      }
    });

    testWidgets('restart invokes its callback', (tester) async {
      var restarted = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => activeDownloadSheetActions(
              context: context,
              status: 'downloading',
              onPause: () {},
              onResume: () {},
              onRestart: () => restarted = true,
              onCancel: () {},
            ),
          ),
        ),
      ));

      await tester.tap(find.byKey(const Key('downloads-sheet-restart')));
      await tester.pump();

      expect(restarted, isTrue);
    });
  });

  group('downloadStateLabel', () {
    DownloadTask task(String status, {int attempts = 0}) => DownloadTask(
          id: 't1',
          mediaId: 'm1',
          title: 'Title',
          quality: '1080p',
          status: status,
          recoveryAttempts: attempts,
          createdAt: DateTime(2026, 1, 1),
        );

    test('names the interrupted state', () {
      expect(downloadStateLabel(task('interrupted')), 'Interrupted, resuming');
    });

    test('counts stall retries', () {
      expect(
        downloadStateLabel(task('stalled', attempts: 2)),
        'Stalled, retrying 2 of $maxRecoveryAttempts',
      );
    });

    test('returns an empty label for a healthy download', () {
      expect(downloadStateLabel(task('downloading')), isEmpty);
    });
  });

  testWidgets('an interrupted card offers inline resume', (tester) async {
    var resumed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DownloadRecoveryBanner(
          task: DownloadTask(
            id: 't1',
            mediaId: 'm1',
            title: 'Title',
            quality: '1080p',
            status: 'interrupted',
            createdAt: DateTime(2026, 1, 1),
          ),
          onResume: () => resumed = true,
        ),
      ),
    ));

    expect(find.text('Interrupted, resuming'), findsOneWidget);
    await tester.tap(find.byKey(const Key('downloads-card-resume')));
    await tester.pump();
    expect(resumed, isTrue);
  });
}
