/// Pure decision logic for recovering download tasks.
///
/// Nothing here touches Hive, dio, or a Flutter binding, so every rule can be
/// tested directly. The service applies the decisions; this file only makes
/// them.
library;

import '../../domain/models/download.dart';

/// Named status groups.
///
/// Active-status membership used to be spelled out as string literals at half a
/// dozen call sites, which made adding a status a silent-damage operation. Every
/// site now reads from here instead.
abstract final class DownloadStatusSets {
  /// Every status meaning "this task is somewhere in the pipeline". Used to
  /// decide which partial files to protect from cleanup and whether to show a
  /// progress notification.
  static const Set<String> active = {
    'pending',
    'queued',
    'downloading',
    'transcoding',
    'paused',
    'interrupted',
    'stalled',
  };

  /// Statuses a recovery sweep may act on when no loop is driving the task.
  static const Set<String> recoverable = {
    'pending',
    'downloading',
    'transcoding',
    'interrupted',
    'stalled',
  };

  /// Statuses that consume a concurrency slot while a loop is driving them.
  static const Set<String> running = {'downloading', 'transcoding'};

  /// Statuses no sweep or watchdog ever touches.
  static const Set<String> terminal = {'completed', 'cancelled', 'failed'};
}

/// What the sweep should do with one task.
enum RecoveryAction {
  /// Re-drive it, continuing from its partial file.
  resume,

  /// Park it as queued so the normal queue processor picks it up later.
  requeue,

  /// Ask the server for a fresh transcode job, then drive it.
  reprepare,

  /// Give up and mark it failed so the user can decide.
  fail,
}

class RecoveryDecision {
  final String taskId;
  final RecoveryAction action;

  const RecoveryDecision(this.taskId, this.action);

  @override
  bool operator ==(Object other) =>
      other is RecoveryDecision &&
      other.taskId == taskId &&
      other.action == action;

  @override
  int get hashCode => Object.hash(taskId, action);

  @override
  String toString() => 'RecoveryDecision($taskId, ${action.name})';
}

typedef RecoveryPlan = List<RecoveryDecision>;

/// Consecutive automatic recovery attempts allowed before a task is failed.
const int maxRecoveryAttempts = 3;

/// Decide what to do with every task that claims to be active but has no loop
/// driving it.
///
/// [liveTaskIds] is the set of task ids with a live cancel token. That map is
/// in-memory, so at launch it is empty by construction and every active-looking
/// row is provably an orphan.
RecoveryPlan planRecovery({
  required List<DownloadTask> tasks,
  required Set<String> liveTaskIds,
  required int maxConcurrent,
  required bool autoStart,
}) {
  final plan = <RecoveryDecision>[];

  var slotsUsed = tasks
      .where((t) =>
          liveTaskIds.contains(t.id) &&
          DownloadStatusSets.running.contains(t.status))
      .length;

  final candidates = tasks
      .where((t) => !liveTaskIds.contains(t.id))
      .where((t) => DownloadStatusSets.recoverable.contains(t.status))
      .toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  for (final task in candidates) {
    // The attempts ceiling takes precedence over every other rule.
    if (task.recoveryAttempts >= maxRecoveryAttempts) {
      plan.add(RecoveryDecision(task.id, RecoveryAction.fail));
      continue;
    }

    final wanted = task.status == 'transcoding' && task.transcodeJobId == null
        ? RecoveryAction.reprepare
        : RecoveryAction.resume;

    if (autoStart && slotsUsed < maxConcurrent) {
      plan.add(RecoveryDecision(task.id, wanted));
      slotsUsed++;
    } else {
      plan.add(RecoveryDecision(task.id, RecoveryAction.requeue));
    }
  }

  return plan;
}

/// How long a download may go without moving bytes before it counts as stalled.
const Duration downloadStallWindow = Duration(seconds: 90);

/// Transcodes can legitimately hold a percentage for a while, so they get a
/// longer rope than a byte stream does.
const Duration transcodeStallWindow = Duration(minutes: 5);

enum StallVerdict {
  /// Progress is recent enough.
  healthy,

  /// Nothing has moved for longer than the window for this status.
  stalled,

  /// This status is not stall-assessed (paused, queued, terminal, or already
  /// marked interrupted).
  notApplicable,
}

/// Decide whether [task] has stopped making progress as of [now].
StallVerdict assessStall(DownloadTask task, DateTime now) {
  final window = switch (task.status) {
    'downloading' => downloadStallWindow,
    'transcoding' => transcodeStallWindow,
    _ => null,
  };
  if (window == null) return StallVerdict.notApplicable;

  // Rows written before lastProgressAt existed fall back to createdAt, which
  // for an old row correctly reads as stalled.
  final last = task.lastProgressAt ?? task.createdAt;

  return now.difference(last) > window
      ? StallVerdict.stalled
      : StallVerdict.healthy;
}
