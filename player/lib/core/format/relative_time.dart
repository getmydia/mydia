/// Formats [timestamp] as a coarse relative time ("3 hours ago").
///
/// This is the single implementation for the app. It replaces the copies that
/// had grown in `RemoteDevice`, `ConnectionDiagnostics` and `DevicesScreen`.
///
/// [now] exists so tests can pin the clock.
String formatRelativeTime(DateTime timestamp, {DateTime? now}) {
  final difference = (now ?? DateTime.now()).difference(timestamp);

  if (difference.inMinutes < 1) {
    return 'Just now';
  }
  if (difference.inMinutes < 60) {
    final minutes = difference.inMinutes;
    return '$minutes ${minutes == 1 ? 'minute' : 'minutes'} ago';
  }
  if (difference.inHours < 24) {
    final hours = difference.inHours;
    return '$hours ${hours == 1 ? 'hour' : 'hours'} ago';
  }
  if (difference.inDays < 30) {
    final days = difference.inDays;
    return '$days ${days == 1 ? 'day' : 'days'} ago';
  }
  if (difference.inDays < 365) {
    final months = (difference.inDays / 30).floor();
    return '$months ${months == 1 ? 'month' : 'months'} ago';
  }
  final years = (difference.inDays / 365).floor();
  return '$years ${years == 1 ? 'year' : 'years'} ago';
}
