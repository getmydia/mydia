import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_recovery.dart';
import 'package:player/domain/models/download.dart';

final base = DateTime(2026, 1, 1, 12);

DownloadTask task({
  required String status,
  DateTime? lastProgressAt,
  DateTime? createdAt,
}) {
  return DownloadTask(
    id: 't1',
    mediaId: 'm1',
    title: 'Title',
    quality: '1080p',
    status: status,
    lastProgressAt: lastProgressAt,
    createdAt: createdAt ?? base,
  );
}

void main() {
  group('assessStall', () {
    test('a downloading task inside the window is healthy', () {
      final verdict = assessStall(
        task(status: 'downloading', lastProgressAt: base),
        base.add(const Duration(seconds: 89)),
      );
      expect(verdict, StallVerdict.healthy);
    });

    test('a downloading task past the window is stalled', () {
      final verdict = assessStall(
        task(status: 'downloading', lastProgressAt: base),
        base.add(const Duration(seconds: 91)),
      );
      expect(verdict, StallVerdict.stalled);
    });

    test('a transcoding task uses the longer window', () {
      final at2Min = base.add(const Duration(minutes: 2));
      final at6Min = base.add(const Duration(minutes: 6));
      expect(
        assessStall(task(status: 'transcoding', lastProgressAt: base), at2Min),
        StallVerdict.healthy,
      );
      expect(
        assessStall(task(status: 'transcoding', lastProgressAt: base), at6Min),
        StallVerdict.stalled,
      );
    });

    test('paused, queued and terminal tasks are not applicable', () {
      for (final status in [
        'paused',
        'queued',
        'pending',
        'completed',
        'cancelled',
        'failed',
        'interrupted',
      ]) {
        expect(
          assessStall(
            task(status: status, lastProgressAt: base),
            base.add(const Duration(hours: 1)),
          ),
          StallVerdict.notApplicable,
          reason: 'status $status should not be stall-assessed',
        );
      }
    });

    test('falls back to createdAt when lastProgressAt is null', () {
      final verdict = assessStall(
        task(status: 'downloading', createdAt: base),
        base.add(const Duration(seconds: 91)),
      );
      expect(verdict, StallVerdict.stalled);
    });
  });
}
