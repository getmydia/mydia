// Downloads remembers its place on a television: the grid of downloaded
// titles and the failed-downloads row above it each return focus to the item
// that last had it, keyed by the download group or task, and a first visit to
// the grid lands on its first title on screen rather than whichever sits
// under the control a move came from.
//
// The real DownloadsScreen inside the shell's real content region (see
// `tv_shell_harness.dart`), at 1920x1080, where the grid is eight titles wide.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/storage_quota_providers.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/storage_settings.dart';
import 'package:player/presentation/screens/downloads/downloads_screen.dart';

import '../../../test_utils/tv_shell_harness.dart';

const _source = 'acc1:owner:aa11';

DownloadedMedia _movie(int n) => DownloadedMedia(
      id: 'row-m$n',
      mediaId: 'm$n',
      title: 'Lantern Accord $n',
      quality: '1080p',
      filePath: '/nowhere/m$n',
      fileSize: 1,
      // Newest first in the grid, so m0 leads.
      downloadedAt: DateTime(2026, 1, 30 - n),
      sourceId: _source,
    );

DownloadTask _failed(int n) => DownloadTask(
      id: 'failed-$n',
      mediaId: 'x$n',
      title: 'Quill Harbor $n',
      quality: '1080p',
      status: 'failed',
      createdAt: DateTime(2026, 1, 1),
      sourceId: _source,
    );

void main() {
  group('Downloads focus memory (requires MYDIA_FORCE_TV=true)', () {
    Key group(int n) => ValueKey('download-group-$_source|m$n');
    Key failed(int n) => ValueKey('failed-download-failed-$n');
    const storageSettings = Key('downloads-storage-settings');

    late TvShell shell;

    /// A failed card is a fixed 300px wide, and under the test font (every
    /// glyph a full em square) its Dismiss and Retry buttons need a few
    /// pixels more than that leaves. Real fonts fit. That layout is not what
    /// these tests are about, so its overflow report alone is dropped. The
    /// handler is restored inside the body: the test binding checks it before
    /// any tear-down runs.
    void downloadsTest(
      String description,
      Future<void> Function(WidgetTester tester) body,
    ) =>
        testWidgets(description, (tester) async {
          final reportError = FlutterError.onError;
          FlutterError.onError = (details) {
            final where = [
              for (final node in details.informationCollector?.call() ??
                  const <DiagnosticsNode>[])
                node.toStringDeep(),
            ].join('\n');
            final overflow =
                details.exceptionAsString().contains('overflowed') &&
                    where.contains('failed-download-');
            if (!overflow) reportError?.call(details);
          };
          try {
            await body(tester);
          } finally {
            FlutterError.onError = reportError;
          }
        });

    Future<void> pumpDownloads(
      WidgetTester tester, {
      int failedCount = 0,
    }) async {
      shell = TvShell();
      await shell.pump(
        tester,
        const DownloadsScreen(),
        overrides: [
          downloadedMediaProvider.overrideWith(
              (ref) => Stream.value([for (var n = 0; n < 24; n++) _movie(n)])),
          downloadQueueProvider
              .overrideWith((ref) => Stream.value(const <DownloadTask>[])),
          failedDownloadsProvider.overrideWith((ref) =>
              Stream.value([for (var n = 0; n < failedCount; n++) _failed(n)])),
          storageQuotaStatusProvider.overrideWith(
            (ref) async => const StorageQuotaStatus(
              usedBytes: 1,
              maxBytes: null,
              usagePercentage: 0,
              isWarningExceeded: false,
              isFull: false,
              remainingBytes: -1,
              settings: StorageSettings(),
            ),
          ),
        ],
      );
    }

    downloadsTest(
        'the grid entered for the first time lands on its first title',
        (tester) async {
      await pumpDownloads(tester);
      // At the far right, over the grid's last column.
      await focusIn(tester, storageSettings);

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectFocusIn(group(0));
    });

    downloadsTest('the grid is re-entered on the title that left it',
        (tester) async {
      await pumpDownloads(tester, failedCount: 3);
      // Under the third failed card, so UP enters the failed row (further
      // right it reaches the row's Retry all button instead).
      await focusIn(tester, group(3));

      await press(tester, LogicalKeyboardKey.arrowUp);
      // The failed row is entered on its first card, not the one above.
      expectFocusIn(failed(0));
      // A sideways move, to the card's other button, so the DOWN below is
      // not a replay of Flutter's own up/down history.
      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(failed(0));

      await press(tester, LogicalKeyboardKey.arrowDown);

      expectFocusIn(group(3));
    });

    downloadsTest('the failed row is re-entered on the card that left it',
        (tester) async {
      await pumpDownloads(tester, failedCount: 3);
      await focusIn(tester, failed(2));
      await press(tester, LogicalKeyboardKey.arrowDown);
      // Over and back along the grid's first row.
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowLeft);

      await press(tester, LogicalKeyboardKey.arrowUp);

      expectFocusIn(failed(2));
    });

    downloadsTest(
        "LEFT from the grid's first column reaches the rail, RIGHT "
        'returns', (tester) async {
      await pumpDownloads(tester);
      await focusIn(tester, group(8));

      await press(tester, LogicalKeyboardKey.arrowLeft);
      expect(shell.sidebarRow.hasPrimaryFocus, isTrue,
          reason: 'focus is on ${describeFocus()}');

      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(group(8));
    });
  }, skip: tvSkipReason);
}
