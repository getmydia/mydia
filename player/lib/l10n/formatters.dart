/// Turns typed values from core and domain code into viewer-facing text.
///
/// Core code never builds sentences: it returns enums, durations and dates,
/// and widgets format them here with `context.l10n`.
library;

import 'package:intl/intl.dart';

import '../domain/models/remote_device.dart';
import 'gen/app_localizations.dart';

extension AppFormatters on AppLocalizations {
  /// A coarse relative time ("3 hours ago"). [now] pins the clock in tests.
  String relativeTime(DateTime timestamp, {DateTime? now}) {
    final d = (now ?? DateTime.now()).difference(timestamp);
    if (d.inMinutes < 1) return timeJustNow;
    if (d.inMinutes < 60) return timeMinutesAgo(d.inMinutes);
    if (d.inHours < 24) return timeHoursAgo(d.inHours);
    if (d.inDays < 30) return timeDaysAgo(d.inDays);
    if (d.inDays < 365) return timeMonthsAgo(d.inDays ~/ 30);
    return timeYearsAgo(d.inDays ~/ 365);
  }

  /// Download time remaining.
  String remainingTime(Duration eta) {
    final s = eta.inSeconds;
    if (s < 60) return timeSecondsLeft(s);
    if (s < 3600) return timeMinutesLeft((s / 60).ceil());
    return timeHoursMinutesLeft(s ~/ 3600, (s % 3600) ~/ 60);
  }

  /// A runtime: 45m, 2h, 1h 20m.
  String runtime(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    if (hours == 0) return durationMinutes(minutes);
    return minutes > 0
        ? durationHoursMinutes(hours, minutes)
        : durationHours(hours);
  }

  /// Month and day, with the year when it is not [now]'s year.
  String watchedDate(DateTime watchedAt, DateTime now) {
    final local = watchedAt.toLocal();
    return local.year == now.year
        ? DateFormat.MMMd(localeName).format(local)
        : DateFormat.yMMMd(localeName).format(local);
  }

  String remoteDeviceStatus(RemoteDeviceStatus status) => switch (status) {
        RemoteDeviceStatus.revoked => settingsDevicesStatusRevoked,
        RemoteDeviceStatus.neverActive => remoteDeviceNeverActive,
        RemoteDeviceStatus.active => settingsDevicesStatusActive,
        RemoteDeviceStatus.inactive => settingsDevicesStatusInactive,
      };
}
