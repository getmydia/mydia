/// Formats a bitrate in kilobits per second as a human-readable rate
/// ("6.2 Mb/s").
///
/// This is the single implementation for the app, beside
/// [formatRelativeTime] and for the same reason: the stats panel renders a
/// measured throughput and a file's own static bitrate with identical
/// wording, and two copies of the rounding would drift.
library;

String formatBitrate(int kbps) {
  if (kbps < 1000) return '$kbps kb/s';
  final tenths = (kbps / 100).round();
  return '${tenths ~/ 10}.${tenths % 10} Mb/s';
}
