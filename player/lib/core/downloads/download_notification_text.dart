/// What the Android foreground-service notification says about the downloads
/// in flight. Pure, so the privacy rule can be tested without a device.
library;

import '../../domain/models/download.dart';
import '../sources/source.dart';

class DownloadNotificationText {
  const DownloadNotificationText({
    required this.title,
    required this.text,
    this.progress = 0,
    this.indeterminate = false,
  });

  final String title;
  final String text;
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
  String label(DownloadTask t, String suffix) =>
      isDiscreet(t.source) ? 'Downloading' : '${t.title} — $suffix';

  if (active.length == 1) {
    final task = active.first;
    final pct = (fractionOf(task) * 100).round();
    if (task.status == 'transcoding') {
      return DownloadNotificationText(
          title: 'Downloading', text: label(task, 'Preparing'), progress: pct);
    }
    if (task.status == 'downloading') {
      return DownloadNotificationText(
          title: 'Downloading', text: label(task, '$pct%'), progress: pct);
    }
    return DownloadNotificationText(
      title: 'Downloading',
      text: isDiscreet(task.source) ? 'Downloading' : task.title,
      indeterminate: true,
    );
  }

  final title = 'Downloading ${active.length} items';
  final running = active.where(progressing).toList();
  if (running.isEmpty) {
    return DownloadNotificationText(
        title: title, text: 'Waiting...', indeterminate: true);
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
    title: title,
    text: shown == null
        ? 'Downloading'
        : label(shown, '${(fractionOf(shown) * 100).round()}%'),
    progress: (average * 100).round(),
  );
}
