import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_recovery.dart';
import 'package:player/domain/models/download.dart';

DownloadTask task(
  String id, {
  required String status,
  int attempts = 0,
  bool progressive = false,
  String? jobId,
  int createdAtMinute = 0,
}) {
  return DownloadTask(
    id: id,
    mediaId: 'media-$id',
    title: 'Title $id',
    quality: '1080p',
    status: status,
    isProgressive: progressive,
    transcodeJobId: jobId,
    recoveryAttempts: attempts,
    createdAt: DateTime(2026, 1, 1).add(Duration(minutes: createdAtMinute)),
  );
}

void main() {
  group('DownloadStatusSets', () {
    test('active covers every non-terminal status', () {
      expect(DownloadStatusSets.active, contains('interrupted'));
      expect(DownloadStatusSets.active, contains('stalled'));
      expect(DownloadStatusSets.active, contains('transcoding'));
      expect(DownloadStatusSets.active, contains('queued'));
      expect(
        DownloadStatusSets.active.intersection(DownloadStatusSets.terminal),
        isEmpty,
      );
    });

    test('running is the subset that consumes a concurrency slot', () {
      expect(DownloadStatusSets.running, {'downloading', 'transcoding'});
    });
  });

  group('planRecovery', () {
    test('leaves live tasks alone', () {
      final plan = planRecovery(
        tasks: [task('a', status: 'downloading')],
        liveTaskIds: {'a'},
        maxConcurrent: 2,
        autoStart: true,
      );
      expect(plan, isEmpty);
    });

    test('resumes an orphaned downloading task', () {
      final plan = planRecovery(
        tasks: [task('a', status: 'downloading')],
        liveTaskIds: const {},
        maxConcurrent: 2,
        autoStart: true,
      );
      expect(plan, [const RecoveryDecision('a', RecoveryAction.resume)]);
    });

    test('resumes orphaned pending, interrupted and stalled tasks', () {
      for (final status in ['pending', 'interrupted', 'stalled']) {
        final plan = planRecovery(
          tasks: [task('a', status: status)],
          liveTaskIds: const {},
          maxConcurrent: 2,
          autoStart: true,
        );
        expect(plan, [const RecoveryDecision('a', RecoveryAction.resume)],
            reason: 'status $status should resume');
      }
    });

    test('ignores queued, paused and terminal tasks', () {
      for (final status in [
        'queued',
        'paused',
        'completed',
        'cancelled',
        'failed'
      ]) {
        final plan = planRecovery(
          tasks: [task('a', status: status)],
          liveTaskIds: const {},
          maxConcurrent: 2,
          autoStart: true,
        );
        expect(plan, isEmpty, reason: 'status $status should be left alone');
      }
    });

    test('re-prepares a transcoding orphan that has no job id', () {
      final plan = planRecovery(
        tasks: [task('a', status: 'transcoding', progressive: true)],
        liveTaskIds: const {},
        maxConcurrent: 2,
        autoStart: true,
      );
      expect(plan, [const RecoveryDecision('a', RecoveryAction.reprepare)]);
    });

    test('resumes a transcoding orphan that still has a job id', () {
      final plan = planRecovery(
        tasks: [
          task('a', status: 'transcoding', progressive: true, jobId: 'job-1')
        ],
        liveTaskIds: const {},
        maxConcurrent: 2,
        autoStart: true,
      );
      expect(plan, [const RecoveryDecision('a', RecoveryAction.resume)]);
    });

    test('the attempts ceiling wins over every other rule', () {
      final plan = planRecovery(
        tasks: [
          task('a', status: 'downloading', attempts: 3),
          task('b', status: 'transcoding', progressive: true, attempts: 4),
        ],
        liveTaskIds: const {},
        maxConcurrent: 4,
        autoStart: true,
      );
      expect(plan, [
        const RecoveryDecision('a', RecoveryAction.fail),
        const RecoveryDecision('b', RecoveryAction.fail),
      ]);
    });

    test('requeues past the concurrency limit, oldest first', () {
      final plan = planRecovery(
        tasks: [
          task('new', status: 'downloading', createdAtMinute: 10),
          task('old', status: 'downloading', createdAtMinute: 1),
          task('mid', status: 'downloading', createdAtMinute: 5),
        ],
        liveTaskIds: const {},
        maxConcurrent: 2,
        autoStart: true,
      );
      expect(plan, [
        const RecoveryDecision('old', RecoveryAction.resume),
        const RecoveryDecision('mid', RecoveryAction.resume),
        const RecoveryDecision('new', RecoveryAction.requeue),
      ]);
    });

    test('counts live running tasks against the concurrency limit', () {
      final plan = planRecovery(
        tasks: [
          task('live', status: 'downloading'),
          task('orphan', status: 'downloading', createdAtMinute: 1),
        ],
        liveTaskIds: {'live'},
        maxConcurrent: 1,
        autoStart: true,
      );
      expect(plan, [const RecoveryDecision('orphan', RecoveryAction.requeue)]);
    });

    test('requeues everything when autoStart is off', () {
      final plan = planRecovery(
        tasks: [
          task('a', status: 'downloading'),
          task('b', status: 'transcoding', progressive: true),
        ],
        liveTaskIds: const {},
        maxConcurrent: 4,
        autoStart: false,
      );
      expect(plan, [
        const RecoveryDecision('a', RecoveryAction.requeue),
        const RecoveryDecision('b', RecoveryAction.requeue),
      ]);
    });
  });
}
