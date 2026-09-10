// The readout is the only way to ask an iPhone what its fullscreen module
// decided: `debugPrint` needs a Mac with Web Inspector attached, and the
// reporter has neither. `rows` is shared by the on-screen section and the copy
// button so the two cannot drift, which is the usual failure of a
// hand-maintained "copy diagnostics" that lists fewer fields than the screen
// above it.

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/fullscreen/fullscreen_failure.dart';
import 'package:player/core/player/fullscreen/fullscreen_mode.dart';
import 'package:player/core/player/fullscreen/fullscreen_report.dart';

void main() {
  group('FullscreenReport.rows', () {
    test('always names the route and whether it is usable', () {
      const report = FullscreenReport(
        mode: FullscreenMode.documentElement,
        ready: true,
      );

      expect(report.rows, contains(('Route', 'documentElement')));
      expect(report.rows, contains(('Ready', 'yes')));
    });

    test('reports the media element only where the route needs one', () {
      const document = FullscreenReport(
        mode: FullscreenMode.documentElement,
        ready: true,
      );
      const video = FullscreenReport(
        mode: FullscreenMode.nativeVideoElement,
        ready: false,
      );

      expect(
        document.rows.map((row) => row.$1),
        isNot(contains('Media element')),
      );
      expect(video.rows, contains(('Media element', 'not bound')));
    });

    test('a fallback that happened is visible', () {
      const report = FullscreenReport(
        mode: FullscreenMode.nativeVideoElement,
        ready: true,
        mediaElementBound: true,
        demoted: true,
      );

      expect(report.rows, contains(('Fell back', 'yes')));
    });

    test('carries both probe answers on web and neither on native', () {
      const web = FullscreenReport(
        mode: FullscreenMode.documentElement,
        ready: true,
        documentFullscreenEnabled: true,
        videoElementFullscreenSupported: false,
      );
      const native = FullscreenReport(
        mode: FullscreenMode.osWindow,
        ready: true,
      );

      expect(web.rows, contains(('document.fullscreenEnabled', 'true')));
      expect(web.rows, contains(('Video element fullscreen', 'false')));
      expect(
        native.rows.map((row) => row.$1),
        isNot(contains('document.fullscreenEnabled')),
      );
    });

    test('the last failure carries its cause and the platform detail', () {
      const report = FullscreenReport(
        mode: FullscreenMode.unsupported,
        ready: false,
        lastFailure: FullscreenFailure(
          FullscreenFailureCause.documentRequestRejected,
          detail: 'NotAllowedError',
        ),
      );

      final failure = report.rows.firstWhere((row) => row.$1 == 'Last failure');
      expect(failure.$2, contains('requestFullscreen was rejected'));
      expect(failure.$2, contains('NotAllowedError'));
    });
  });

  group('fullscreenReportLines', () {
    test('a session that never played contributes nothing', () {
      expect(fullscreenReportLines(null), isEmpty);
    });

    test('every row on screen is in the copied text', () {
      const report = FullscreenReport(
        mode: FullscreenMode.nativeVideoElement,
        ready: true,
        mediaElementBound: true,
        demoted: true,
        documentFullscreenEnabled: true,
        videoElementFullscreenSupported: true,
      );

      final lines = fullscreenReportLines(report);

      expect(lines.first, 'Fullscreen:');
      for (final (label, value) in report.rows) {
        expect(lines, contains('  $label: $value'));
      }
    });
  });
}
