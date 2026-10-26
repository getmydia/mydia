/// What the Android foreground-service notification says about the downloads
/// in flight. Pure, so the privacy rule can be tested without a device.
///
/// It returns what to say, not the words: `AppFormatters.downloadNotification*`
/// words it in the viewer's language where the notification is posted.
library;

import '../../domain/models/download.dart';
import '../sources/source.dart';

/// The second line of the notification.
sealed class DownloadNotificationLine {
  const DownloadNotificationLine();
}

/// Only that something is downloading: a discreet source never gets named.
class NotificationDownloading extends DownloadNotificationLine {
  const NotificationDownloading();
}

class NotificationWaiting extends DownloadNotificationLine {
  const NotificationWaiting();
}

/// A task's title alone, before any progress is known.
class NotificationTaskTitle extends DownloadNotificationLine {
  const NotificationTaskTitle(this.title);
  final String title;
}

class NotificationPreparing extends DownloadNotificationLine {
  const NotificationPreparing(this.title);
  final String title;
}

class NotificationProgress extends DownloadNotificationLine {
  const NotificationProgress(this.title, this.percent);
  final String title;
  final int percent;
}

class DownloadNotificationText {
  const DownloadNotificationText({
    required this.count,
    required this.line,
    this.progress = 0,
    this.indeterminate = false,
  });

  /// How many downloads are active; the title says so when it is more than one.
  final int count;
  final DownloadNotificationLine line;
  final int progress;
  final bool indeterminate;
}

/// Summarises [active] (a non-empty list of active tasks).
///
/// A task of a discreet source (locked or hidden) contributes to the count and
/// the progress but never to the text: the notification shows on the lock
/// screen, and a title there would give the hidden source away.
DownloadNotificationText buildDownloadNotificationText(
  List<DownloadTask> active,
  bool Function(SourceId source) isDiscreet,
) {
  bool progressing(DownloadTask t) =>
      t.status == 'downloading' || t.status == 'transcoding';
  double fractionOf(DownloadTask t) =>
      t.status == 'transcoding' ? t.transcodeProgress : t.progress;
  DownloadNotificationLine progressLine(DownloadTask t, int percent) =>
      isDiscreet(t.source)
          ? const NotificationDownloading()
          : NotificationProgress(t.title, percent);

  if (active.length == 1) {
    final task = active.first;
    final pct = (fractionOf(task) * 100).round();
    if (task.status == 'transcoding') {
      return DownloadNotificationText(
        count: 1,
        line: isDiscreet(task.source)
            ? const NotificationDownloading()
            : NotificationPreparing(task.title),
        progress: pct,
      );
    }
    if (task.status == 'downloading') {
      return DownloadNotificationText(
        count: 1,
        line: progressLine(task, pct),
        progress: pct,
      );
    }
    return DownloadNotificationText(
      count: 1,
      line: isDiscreet(task.source)
          ? const NotificationDownloading()
          : NotificationTaskTitle(task.title),
      indeterminate: true,
    );
  }

  final running = active.where(progressing).toList();
  if (running.isEmpty) {
    return DownloadNotificationText(
      count: active.length,
      line: const NotificationWaiting(),
      indeterminate: true,
    );
  }
  final average = running.fold<double>(0.0, (sum, t) => sum + fractionOf(t)) /
      running.length;
  // Name a visible task when there is one; otherwise name nothing.
  final named = running.where((t) => !isDiscreet(t.source)).toList();
  final shown = named.isEmpty
      ? null
      : named.firstWhere((t) => t.status == 'downloading',
          orElse: () => named.first);
  return DownloadNotificationText(
    count: active.length,
    line: shown == null
        ? const NotificationDownloading()
        : progressLine(shown, (fractionOf(shown) * 100).round()),
    progress: (average * 100).round(),
  );
}
