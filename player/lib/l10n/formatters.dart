/// Turns typed values from core and domain code into viewer-facing text.
///
/// Core code never builds sentences: it returns enums, durations and dates,
/// and widgets format them here with `context.l10n`.
library;

import 'package:intl/intl.dart';

import '../core/playback/playback_plan.dart';
import '../core/player/fullscreen/fullscreen_failure.dart';
import '../core/player/subtitle_size.dart';
import '../core/theme/glass_material.dart';
import '../core/theme/theme_preset.dart';
import '../core/update/update_provider.dart';
import '../core/update/update_track.dart';
import '../domain/models/quality_rung.dart';
import '../domain/models/remote_device.dart';
import '../domain/sources/item.dart';
import '../presentation/screens/calendar/calendar_dates.dart';
import '../presentation/screens/login/login_failure.dart';
import 'gen/app_localizations.dart';

extension AppFormatters on AppLocalizations {
  /// The sign-in error line for [failure]; the server's own words verbatim.
  String loginFailure(LoginFailure failure) => switch (failure) {
        LoginFailureFromServer(:final message) => message,
        LoginFailureOfKind(:final kind) => switch (kind) {
            LoginFailureKind.cannotConnect => loginErrorCannotConnect,
            LoginFailureKind.serverNotFound => loginErrorServerNotFound,
            LoginFailureKind.invalidCredentials => loginErrorInvalidCredentials,
            LoginFailureKind.loginFailed => loginErrorFailed,
            LoginFailureKind.invalidCode => loginErrorInvalidCode,
            LoginFailureKind.signInExpired => loginErrorSignInExpired,
            LoginFailureKind.tooManyAttempts => loginErrorTooManyAttempts,
          },
      };

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

  /// `Mon` for any Monday.
  String weekdayShort(DateTime day) => DateFormat.E(localeName).format(day);

  /// `M` for any Monday; a single letter, for the month grid's header.
  String weekdayNarrow(DateTime day) =>
      DateFormat.EEEEE(localeName).format(day);

  /// `October` for any day in October.
  String monthName(DateTime day) => DateFormat.MMMM(localeName).format(day);

  /// `October 2026`, always naming the year.
  String monthYear(DateTime month) =>
      DateFormat.yMMMM(localeName).format(month);

  /// The month button's label: the month, with the year when it is not
  /// [today]'s year.
  String monthLabel(DateTime month, DateTime today) =>
      month.year == today.year ? monthName(month) : monthYear(month);

  /// `S02E05` for an episode, the word for a movie.
  String calendarNumbering(ItemSummary entry) =>
      entry.episodeCode ?? calendarMovie;

  /// The numbering, then the episode title when there is one.
  String calendarSubtitle(ItemSummary entry) {
    final code = entry.episodeCode;
    if (code == null || entry.title.isEmpty) return calendarNumbering(entry);
    return '$code · ${entry.title}';
  }

  String remoteDeviceStatus(RemoteDeviceStatus status) => switch (status) {
        RemoteDeviceStatus.revoked => settingsDevicesStatusRevoked,
        RemoteDeviceStatus.neverActive => remoteDeviceNeverActive,
        RemoteDeviceStatus.active => settingsDevicesStatusActive,
        RemoteDeviceStatus.inactive => settingsDevicesStatusInactive,
      };

  String themePresetName(ThemePreset preset) => switch (preset) {
        ThemePreset.projectionBooth => themePresetProjectionBooth,
        ThemePreset.oledBlack => themePresetOledBlack,
        ThemePreset.slate => themePresetSlate,
        ThemePreset.macos => themePresetMacos,
      };

  String glassMaterialName(GlassMaterial material) => switch (material) {
        GlassMaterial.liquid => glassMaterialLiquid,
        GlassMaterial.frosted => glassMaterialFrosted,
      };

  String subtitleSizeName(SubtitleSize size) => switch (size) {
        SubtitleSize.small => subtitleSizeSmall,
        SubtitleSize.medium => subtitleSizeMedium,
        SubtitleSize.large => subtitleSizeLarge,
        SubtitleSize.extraLarge => subtitleSizeExtraLarge,
      };

  String updateTrackName(UpdateTrack track) => switch (track) {
        UpdateTrack.stable => updateTrackStable,
        UpdateTrack.beta => updateTrackBeta,
        UpdateTrack.dev => updateTrackDev,
      };

  String updateTrackDescription(UpdateTrack track) => switch (track) {
        UpdateTrack.stable => updateTrackStableDescription,
        UpdateTrack.beta => updateTrackBetaDescription,
        UpdateTrack.dev => updateTrackDevDescription,
      };

  /// Auto and Original are words; a capped rung is its own label, a
  /// resolution such as "720p" that reads the same in every language.
  String qualityName(QualityRung rung) {
    if (rung.isAuto) return qualityAuto;
    if (rung.isOriginal) return qualityOriginal;
    return rung.label;
  }

  /// The toast for a refused fullscreen request. A refused exit says so,
  /// because "could not enter" would describe the opposite of what was asked.
  String fullscreenFailureMessage(FullscreenFailure failure) =>
      switch (failure.cause) {
        FullscreenFailureCause.documentExitRejected ||
        FullscreenFailureCause.videoExitFailed =>
          fullscreenExitFailed,
        FullscreenFailureCause.documentEnabledProbeFailed ||
        FullscreenFailureCause.videoSupportProbeFailed ||
        FullscreenFailureCause.documentRequestRejected ||
        FullscreenFailureCause.playerNotWebPlayer ||
        FullscreenFailureCause.noVideoElement ||
        FullscreenFailureCause.videoEnterFailed =>
          fullscreenEnterFailed,
      };

  /// The error line under the update card, or null when there is none.
  String? updateErrorMessage(UpdateState state) {
    final unpublished = state.trackNotPublished;
    if (unpublished == null) return state.error;
    final track = updateTrackName(unpublished.track);
    return unpublished.macos
        ? updateTrackNotPublishedMacos(track)
        : updateTrackNotPublished(track);
  }

  /// The Auto row's subtitle for [plan]: what Auto is doing, or would do.
  ///
  /// [effective] is the rung the server echoed for a transcode, which on a
  /// relay can sit below the one Auto asked for; the row names what is
  /// actually playing.
  String autoDeliverySubtitle(PlaybackPlan plan, {QualityRung? effective}) =>
      switch (plan) {
        DirectPlayPlan() => qualityAutoDirectPlay,
        HlsPlan(strategy: HlsStrategy.copy) => qualityAutoCopy,
        HlsPlan(:final rung) => _autoTranscodeSubtitle(effective ?? rung),
      };

  String _autoTranscodeSubtitle(QualityRung rung) => rung.isOriginal
      ? qualityAutoReencodeOriginal
      : qualityAutoRung(qualityName(rung));
}
