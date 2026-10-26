/// Turns typed values from core and domain code into viewer-facing text.
///
/// Core code never builds sentences: it returns enums, durations and dates,
/// and widgets format them here with `context.l10n`.
library;

import 'package:intl/intl.dart';

import '../core/channels/pairing_service.dart';
import '../core/connection/connection_summary.dart';
import '../core/downloads/download_notification_text.dart';
import '../core/logging/log_uploader.dart';
import '../core/playback/loading_step.dart';
import '../core/playback/playback_memory.dart' show FailureReason;
import '../core/playback/playback_plan.dart';
import '../core/playback/stats/playback_stats.dart';
import '../core/playback/stats/stats_report.dart';
import '../core/player/fullscreen/fullscreen_failure.dart';
import '../core/player/subtitle_size.dart';
import '../core/player/video_scaling.dart';
import '../core/remote/registration_status.dart';
import '../core/router/push_route.dart';
import '../core/theme/glass_material.dart';
import '../core/theme/theme_preset.dart';
import '../core/update/update_problem.dart';
import '../core/update/update_provider.dart';
import '../core/update/update_track.dart';
import '../domain/models/audio_track.dart';
import '../domain/models/download.dart';
import '../domain/models/download_failure.dart';
import '../domain/models/media_segment.dart';
import '../domain/models/quality_delivery_subtitle.dart';
import '../domain/models/quality_rung.dart';
import '../domain/models/remote_device.dart';
import '../domain/models/storage_settings.dart';
import '../domain/models/subtitle_search_outcome.dart';
import '../domain/models/subtitle_track.dart';
import '../domain/navigation/media_filter.dart';
import '../domain/navigation/nav_destination.dart';
import '../domain/navigation/source_nav.dart';
import '../domain/sources/item.dart';
import '../domain/sources/library.dart';
import '../domain/sources/source_error.dart';
import '../presentation/screens/calendar/calendar_dates.dart';
import '../presentation/screens/library/library_sort.dart';
import '../presentation/screens/login/login_failure.dart';
import '../presentation/screens/player/subtitle_track_builder.dart'
    show SubtitleDelayNotice, SubtitleDelayNoticeKind, SubtitleNotice;
import 'gen/app_localizations.dart';

extension AppFormatters on AppLocalizations {
  /// The sentence for a failed source call. The server's own words are shown
  /// verbatim; the app's own failures and every other error get a translated
  /// sentence, never the error's `toString`.
  String sourceError(Object error) {
    if (error is! SourceException) return sourcesErrorGeneric;
    final fault = error.fault;
    if (fault != null) return sourceFaultText(fault, error.detail);
    final message = error.message;
    return switch (error.kind) {
      SourceErrorKind.unreachable => sourceErrorUnreachable,
      SourceErrorKind.unauthorized => sourceErrorUnauthorized,
      SourceErrorKind.notFound => sourceErrorNotFound,
      SourceErrorKind.unsupported => message ?? sourceErrorUnsupported,
      SourceErrorKind.server => message ?? sourceErrorServer,
      SourceErrorKind.wrongPin => sourceErrorWrongPin,
    };
  }

  /// The detail to put inside a sentence such as "Sync failed: {detail}": a
  /// source failure is worded in the viewer's language, anything else is the
  /// error's own technical text.
  String failureDetail(Object error) =>
      error is SourceException ? sourceError(error) : '$error';

  /// The sentence for a failure the app recognised itself. [detail] is the
  /// HTTP status or the server's status word the sentence names.
  String sourceFaultText(SourceFault fault, String? detail) {
    final value = detail ?? '';
    return switch (fault) {
      SourceFault.serverGone => sourceFaultServerGone,
      SourceFault.serverRefused => sourceFaultServerRefused,
      SourceFault.serverHttp => sourceFaultServerHttp(value),
      SourceFault.serverUnreadable ||
      SourceFault.stashUnreadable =>
        sourceFaultServerUnreadable,
      SourceFault.serverNoData => sourceFaultServerNoData,
      SourceFault.noFileToDownload => sourceFaultNoFileToDownload,
      SourceFault.mydiaBadServerId => sourceFaultMydiaBadServerId,
      SourceFault.mydiaWrongServerCode => sourceFaultMydiaWrongServerCode,
      SourceFault.mydiaNoServerId => sourceFaultMydiaNoServerId,
      SourceFault.jellyfinNoSession => sourceFaultJellyfinNoSession,
      SourceFault.jellyfinNoQuickConnectCode =>
        sourceFaultJellyfinNoQuickConnectCode,
      SourceFault.jellyfinUnexpectedSignIn =>
        sourceFaultJellyfinUnexpectedSignIn,
      SourceFault.jellyfinNotJellyfin => sourcesJellyfinNotJellyfin,
      SourceFault.jellyfinUnreadable => sourceFaultJellyfinUnreadable,
      SourceFault.jellyfinNotAllowed => sourceFaultJellyfinNotAllowed,
      SourceFault.jellyfinNoCompatibleStream =>
        sourceFaultJellyfinNoCompatibleStream,
      SourceFault.jellyfinRateLimited => sourceFaultJellyfinRateLimited,
      SourceFault.jellyfinRefused => sourceFaultJellyfinRefused(value),
      SourceFault.plexUnreadable => sourceFaultPlexUnreadable,
      SourceFault.plexTvUnexpected => sourceFaultPlexTvUnexpected,
      SourceFault.plexNoDirectFile => sourceFaultPlexNoDirectFile,
      SourceFault.plexNoServersForUser => sourceFaultPlexNoServersForUser,
      SourceFault.plexRefusedConvert => sourceFaultPlexRefusedConvert,
      SourceFault.stashHttp => sourceFaultStashHttp(value),
      SourceFault.stashUnexpectedReply => sourceFaultStashUnexpectedReply,
      SourceFault.stashReportedError => sourceFaultStashReportedError,
      SourceFault.stashStatus => sourceFaultStashStatus(value),
      SourceFault.stashNotConfirmed => sourceFaultStashNotConfirmed,
    };
  }

  /// The reason line on a failed or interrupted download card.
  String downloadFailureText(DownloadFailure failure) {
    final detail = failure.detail ?? '';
    return switch (failure.code) {
      DownloadFailureCode.cancelled => downloadsFailureCancelled,
      DownloadFailureCode.stalled =>
        downloadsFailureStalled(failure.count ?? 0),
      DownloadFailureCode.startingUp => downloadsFailureStartingUp,
      DownloadFailureCode.source => sourceError(failure.sourceException()),
      DownloadFailureCode.transcodeFailed => downloadsFailureTranscode(detail),
      DownloadFailureCode.networkRetries =>
        downloadsFailureNetworkRetries(failure.count ?? 0, detail),
      DownloadFailureCode.network => downloadsFailureNetwork(detail),
      DownloadFailureCode.networkKind => downloadsFailureNetworkKind(detail),
      DownloadFailureCode.jobGone => downloadsFailureJobGone,
      DownloadFailureCode.signInExpired => sourceErrorUnauthorized,
      DownloadFailureCode.itemGone => sourceErrorNotFound,
      DownloadFailureCode.unknown => failure.detail ?? downloadsFailedFallback,
    };
  }

  /// The line under the update card for [problem].
  String updateProblemText(UpdateProblem problem) {
    final issue = problem.issue;
    if (issue == null) return problem.text ?? updateFailedGeneric;
    final detail = problem.detail ?? '';
    return switch (issue) {
      UpdateIssue.installPermissionDenied => updateInstallPermissionDenied,
      UpdateIssue.installPermissionStillDenied =>
        updateInstallPermissionStillDenied,
      UpdateIssue.installerUnavailable => updateInstallerUnavailable,
      UpdateIssue.needsNewPermissions => updateNeedsNewPermissions,
      UpdateIssue.portalUnreachable => updatePortalUnreachable,
      UpdateIssue.noResult => updateNoResult,
      UpdateIssue.updateFailed => updateFailedGeneric,
      UpdateIssue.installFailed => updateInstallFailed(detail),
      UpdateIssue.checkFailed => updateCheckFailed(detail),
      UpdateIssue.saveChoiceFailed => updateSaveChoiceFailed(detail),
      UpdateIssue.saveChoiceFailedMacos => updateSaveChoiceFailedMacos,
      UpdateIssue.checksumMismatch => updateChecksumMismatch,
      UpdateIssue.extractFailed => updateExtractFailed(detail),
      UpdateIssue.copyFailed => updateCopyFailed(detail),
      UpdateIssue.chmodFailed => updateChmodFailed(detail),
      UpdateIssue.notAnAppImage => updateNotAnAppImage,
    };
  }

  /// The sign-in error line for [failure]; the server's own words verbatim.
  String loginFailure(LoginFailure failure) => switch (failure) {
        LoginFailureFromServer(:final message) => message,
        LoginFailureOfSource(:final error) => sourceError(error),
        LoginFailureOfKind(:final kind) => switch (kind) {
            LoginFailureKind.cannotConnect => loginErrorCannotConnect,
            LoginFailureKind.serverNotFound => loginErrorServerNotFound,
            LoginFailureKind.invalidCredentials => loginErrorInvalidCredentials,
            LoginFailureKind.loginFailed => loginErrorFailed,
            LoginFailureKind.invalidCode => loginErrorInvalidCode,
            LoginFailureKind.signInExpired => loginErrorSignInExpired,
            LoginFailureKind.tooManyAttempts => loginErrorTooManyAttempts,
          },
        LoginFailureOfPairing(:final failure) => switch (failure.kind) {
            PairingFailureKind.serviceUnavailable => loginPairErrorUnavailable,
            PairingFailureKind.cannotConnect => loginPairErrorCannotConnect,
            PairingFailureKind.invalidServerAddress =>
              loginPairErrorInvalidAddress,
            PairingFailureKind.invalidQrServerAddress =>
              loginPairErrorInvalidQrAddress,
            PairingFailureKind.missingTokens => loginPairErrorMissingTokens,
            PairingFailureKind.invalidCode => loginPairErrorInvalidCode,
            PairingFailureKind.tooManyAttempts => loginPairErrorTooManyAttempts,
            PairingFailureKind.serverOffline => loginPairErrorServerOffline,
            PairingFailureKind.timedOut => loginPairErrorTimedOut,
            PairingFailureKind.other => switch (failure.detail) {
                final detail? => loginPairErrorFailed(detail),
                null => loginPairErrorFailedGeneric,
              },
          },
      };

  /// The progress line under the code field while pairing.
  String pairingStepText(PairingStep step) => switch (step) {
        PairingStep.lookingUpCode => loginPairStepLookingUp,
        PairingStep.validatingQr => loginPairStepValidatingQr,
        PairingStep.resolvingCode => loginPairStepResolving,
        PairingStep.initializing => loginPairStepInitializing,
        PairingStep.connecting => loginPairStepConnecting,
        PairingStep.submitting => loginPairStepSubmitting,
        PairingStep.succeeded => loginPairStepSucceeded,
        PairingStep.paired => loginPairStepPaired,
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
    if (unpublished == null) {
      final error = state.error;
      return error == null ? null : updateProblemText(error);
    }
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

  /// The name of the language an ISO 639 [code] (two or three letters) stands
  /// for, in the viewer's language. A code with no name here comes back upper
  /// cased; null and empty give null.
  String? languageName(String? code) {
    if (code == null || code.isEmpty) return null;
    final key = _languageKeys[code.toLowerCase()];
    return key == null ? code.toUpperCase() : languageNameByCode(key);
  }

  /// The name of a sidebar row: a builtin's by its id, a saved filter's own
  /// words as the viewer typed them.
  String navDestinationLabel(NavDestination destination) =>
      switch (destination) {
        FilterDestination(:final label) => label,
        BuiltinDestination(:final id) => _builtinNavName(id),
      };

  /// The name of a resolved sidebar or bottom bar entry: a library's own name
  /// from its server, else the builtin the entry stands for.
  String navEntryLabel(SourceNavEntry entry) {
    final kind = entry.libraryKind;
    return entry.label ??
        (kind == null
            ? _builtinNavName(entry.id)
            : libraryKindTitle(kind, scenes: entry.libraryScenes));
  }

  /// What the bottom bar shows for [entry]: the short form where it has one.
  String navEntryTabLabel(SourceNavEntry entry) =>
      entry.shortLabel ? navShowsShort : navEntryLabel(entry);

  String _builtinNavName(String id) => switch (id) {
        'search' => navSearch,
        'home' => navHome,
        'continue_watching' => nextUpContinueWatching,
        'movies' => navMovies,
        'shows' => navShows,
        'calendar' => navCalendar,
        'recently_added' => navRecentlyAdded,
        'unwatched' => navUnwatched,
        'favorites' => navFavorites,
        'collections' => navCollections,
        'downloads' => navDownloads,
        'settings' => settingsTitle,
        _ => id,
      };

  /// A library's name: its server's, else one for its kind.
  String libraryTitle(Library library) =>
      library.title ?? libraryKindTitle(library.kind, scenes: library.scenes);

  /// What a library of [kind] is called when its server did not name it.
  String libraryKindTitle(LibraryKind kind, {bool scenes = false}) =>
      switch (kind) {
        LibraryKind.movies => navMovies,
        LibraryKind.shows => navShows,
        LibraryKind.videos => scenes ? libraryTitleScenes : libraryTitleVideos,
      };

  String sortName(SortName name) => switch (name) {
        SortName.title => sortTitle,
        SortName.year => sortYear,
        SortName.recentlyAdded => sortRecentlyAdded,
        SortName.dateAdded => sortDateAdded,
        SortName.rating => sortRating,
        SortName.duration => sortDuration,
        SortName.popularity => sortPopularity,
        SortName.contentRating => sortContentRating,
        SortName.releaseDate => sortReleaseDate,
        SortName.date => sortDate,
        SortName.lastPlayed => sortLastPlayed,
        SortName.lastWatched => sortLastWatched,
        SortName.mostPlayed => sortMostPlayed,
        SortName.watchState => sortWatchState,
        SortName.random => sortRandom,
      };

  /// A library sort sheet row.
  String sortFieldName(SortField field) => switch (field) {
        SortField.title => sortTitle,
        SortField.year => sortYear,
        SortField.addedAt => sortDateAdded,
        SortField.rating => sortRating,
        SortField.runtime => sortDuration,
        SortField.popularity => sortPopularity,
        SortField.contentRating => sortContentRating,
        SortField.releaseDate => sortReleaseDate,
        SortField.lastPlayed => sortLastPlayed,
        SortField.watchState => sortWatchState,
        SortField.random => sortRandom,
      };

  /// A filter chip's name.
  String filterOptionName(FilterOption option) {
    final category = option.category;
    if (category != null) return categoryFilterName(category);
    return switch (option.name!) {
      FilterName.unwatched => navUnwatched,
      FilterName.unplayed => filterUnplayed,
      FilterName.favorites => navFavorites,
      FilterName.inProgress => filterInProgress,
    };
  }

  String categoryFilterName(MediaCategoryFilter category) => switch (category) {
        MediaCategoryFilter.movie => navMovies,
        MediaCategoryFilter.animeMovie => filterCategoryAnimeMovies,
        MediaCategoryFilter.cartoonMovie => filterCategoryCartoonMovies,
        MediaCategoryFilter.tvShow => navShows,
        MediaCategoryFilter.animeSeries => filterCategoryAnimeSeries,
        MediaCategoryFilter.cartoonSeries => filterCategoryCartoonSeries,
      };

  String statsRowLabel(StatsRowId id) => switch (id) {
        StatsRowId.playing => statsRowPlaying,
        StatsRowId.why => statsRowWhy,
        StatsRowId.source => statsRowSource,
        StatsRowId.video => statsRowVideo,
        StatsRowId.decoder => statsRowDecoder,
        StatsRowId.audio => statsRowAudio,
        StatsRowId.frames => statsRowFrames,
        StatsRowId.buffer => statsRowBuffer,
        StatsRowId.throughput => statsRowThroughput,
        StatsRowId.link => statsRowLink,
        StatsRowId.position => statsRowPosition,
      };

  /// Confirms a scaling change, which matters when the video already matches
  /// the screen and the two modes look identical.
  String videoScalingToast(VideoScaling scaling) => switch (scaling) {
        VideoScaling.fit => videoScalingFitToast,
        VideoScaling.fill => videoScalingFillToast,
      };

  /// The badge before the Playing value.
  String statsPill(PlaybackMode mode) => switch (mode) {
        PlaybackMode.direct => statsPillDirect,
        PlaybackMode.copy => statsPillCopy,
        PlaybackMode.transcode => statsPillTranscode,
        PlaybackMode.localFile => statsModeLocalFile,
      };

  String statsModeName(PlaybackMode mode) => switch (mode) {
        PlaybackMode.direct => statsModeDirectPlay,
        PlaybackMode.copy => statsModeStreamCopy,
        PlaybackMode.transcode => statsModeTranscode,
        PlaybackMode.localFile => statsModeLocalFile,
      };

  String statsValue(StatsValue value) => switch (value) {
        StatsText(:final text) => text,
        StatsWhyValue(:final why) => statsWhyText(why),
        StatsQualityValue(:final quality) => statsQualityText(quality),
        StatsModeValue(:final mode) => statsModeName(mode),
        StatsDecoderValue(:final label, :final hardware) => switch (hardware) {
            null => label,
            true => statsDecoderHardware(label),
            false => statsDecoderSoftware(label),
          },
        StatsFramesValue(:final dropped, :final total) =>
          statsFramesDropped(dropped, total),
        // One decimal: a buffer that reads `18 s` for eighteen seconds
        // running looks frozen while `18.4` visibly moves.
        StatsBufferValue(:final ahead) => statsBufferAhead(
            NumberFormat('0.0', localeName)
                .format((ahead.inMilliseconds / 100).round() / 10),
          ),
        StatsPositionValue(:final position, :final duration) =>
          '${statsTimecode(position)} / ${statsTimecode(duration)}',
      };

  /// An audio track's name: its own title, else its language.
  String audioTrackName(AudioTrack track) =>
      _trackName(track.title, track.language);

  /// A subtitle track's name: its own title, else its language.
  String subtitleTrackName(SubtitleTrack track) =>
      _trackName(track.title, track.language);

  String _trackName(String? title, String language) =>
      title != null && title.isNotEmpty
          ? title
          : languageName(language) ?? language;

  /// How the Original rung is delivered, shown under it in the quality picker.
  String originalDeliveryText(OriginalDelivery delivery) => switch (delivery) {
        OriginalDelivery.directPlay => qualityDirectPlay,
        OriginalDelivery.lossless => qualityOriginalLossless,
        OriginalDelivery.transcode => qualityOriginalReencode,
        OriginalDelivery.preference => qualityOriginalPreference,
      };

  /// Under a capped rung: it always re-encodes, up to [maxBitrateKbps] when
  /// the rung has a cap (a rung synthesised from the server's answer may not).
  String cappedRungDeliveryText(int? maxBitrateKbps) => maxBitrateKbps == null
      ? qualityTranscodes
      : qualityTranscodesUpTo(maxBitrateKbps);

  String connectionLabel(ConnectionSummary summary) => switch (summary.kind) {
        ConnectionKind.server => connectionServerLabel,
        ConnectionKind.direct => connectionDirectLabel,
        ConnectionKind.relay => connectionRelayLabel,
        ConnectionKind.mixed => connectionMixedLabel,
        ConnectionKind.reconnecting => connectionReconnectingLabel,
        ConnectionKind.connecting => connectionConnectingLabel,
      };

  /// One sentence of detail under [connectionLabel].
  String connectionDetail(ConnectionSummary summary) => switch (summary.kind) {
        ConnectionKind.server => connectionServerDetail,
        ConnectionKind.direct => connectionDirectDetail,
        ConnectionKind.relay => connectionRelayDetail,
        ConnectionKind.mixed => connectionMixedDetail,
        ConnectionKind.reconnecting => connectionReconnectingDetail,
        ConnectionKind.connecting => connectionConnectingDetail,
      };

  /// The skip button's label for a media segment.
  String segmentSkipLabel(SegmentType type) => switch (type) {
        SegmentType.intro => segmentSkipIntro,
        SegmentType.credits => segmentSkipCredits,
        SegmentType.unknown => segmentSkip,
      };

  /// The message after a remote or cast request to open something was
  /// declined, or null when it was opened.
  String? pushOutcomeMessage(PushOutcome outcome) => switch (outcome) {
        PushOutcome.blockedByPlayer => pushBlockedByPlayer,
        PushOutcome.blockedByForm => pushBlockedByForm,
        PushOutcome.pushed || PushOutcome.pushedAfterClosingPages => null,
      };

  /// The line under a Mydia server's name in the remote registration status.
  String registrationStatusText(RegistrationStatus status) => switch (status) {
        RegistrationIdle() => registrationNotAdvertising,
        RegistrationWaiting(:final dependency) => switch (dependency) {
            RegistrationDependency.remoteControlSetting =>
              registrationWaitingForSetting,
            RegistrationDependency.deviceOnline => registrationWaitingForOnline,
            RegistrationDependency.serverConnection =>
              registrationWaitingForServer,
          },
        RegistrationInFlight(:final attempt) =>
          registrationRegistering(attempt),
        RegistrationSucceeded() => registrationDiscoverable,
        RegistrationFailed(:final reason) =>
          registrationNotDiscoverable(reason),
      };

  String cleanupPolicyName(CleanupPolicy policy) => switch (policy) {
        CleanupPolicy.byDate => storageCleanupOldestFirst,
        CleanupPolicy.lru => storageCleanupLeastRecentlyUsed,
      };

  /// The way a download's size reads, or a word for a size nobody knows.
  String downloadTaskSize(DownloadTask task) =>
      task.fileSizeDisplay ?? downloadsSizeUnknown;

  /// The second line of the downloads notification.
  String downloadNotificationLine(DownloadNotificationLine line) =>
      switch (line) {
        NotificationDownloading() => downloadNotificationDownloading,
        NotificationWaiting() => downloadNotificationWaiting,
        NotificationTaskTitle(:final title) => title,
        NotificationPreparing(:final title) =>
          downloadNotificationPreparing(title),
        NotificationProgress(:final title, :final percent) =>
          downloadNotificationProgress(title, percent),
      };

  /// The line the update card shows when there is nothing left to do.
  String updateNoticeText(UpdateNotice notice) => switch (notice) {
        UpdateNotice.upToDate => settingsUpdateCheckUpToDate,
        UpdateNotice.handedOff => settingsUpdateNoticeHandedOff,
        UpdateNotice.reopenToFinish => settingsUpdateNoticeReopen,
      };

  /// Why sending logs failed.
  String logUploadFailure(LogUploadException error) => switch (error.failure) {
        LogUploadFailure.relayBusy => settingsDiagnosticsRelayBusy,
        LogUploadFailure.relayRejected => settingsDiagnosticsRelayRejected,
        LogUploadFailure.relayNoCode => settingsDiagnosticsRelayNoCode,
        LogUploadFailure.relayUnreachable =>
          settingsDiagnosticsRelayUnreachable,
        LogUploadFailure.relayHttp =>
          settingsDiagnosticsRelayHttp(error.status ?? 0),
        LogUploadFailure.noLogs => settingsDiagnosticsNoLogs,
        LogUploadFailure.unavailable => settingsDiagnosticsLogsUnavailable,
      };

  /// The line under the player's spinner while a stream opens.
  String loadingStepText(LoadingStep step) => switch (step.kind) {
        LoadingStepKind.startingStream => playerLoadingStarting,
        LoadingStepKind.preparingStream => playerLoadingPreparing(step.percent),
        LoadingStepKind.startingTranscode =>
          playerLoadingTranscoding(step.attempt, step.maxAttempts),
        LoadingStepKind.connectingP2p => playerLoadingP2p,
        LoadingStepKind.checkingCompatibility => playerLoadingCompatibility,
      };

  /// The toast after the player switched to transcoding on its own.
  String fallbackMessage(FailureReason reason) => switch (reason) {
        FailureReason.decodeFailed => playerFallbackDecodeFailed,
        FailureReason.decodeTooSlow => playerFallbackDecodeTooSlow,
        FailureReason.bandwidth => playerFallbackBandwidth,
      };

  /// The Why row of the stats panel.
  String statsWhyText(StatsWhy why) => switch (why) {
        StatsWhyPlain(:final kind) => switch (kind) {
            StatsWhyKind.containerNotDirect => statsWhyContainerNotDirect,
            StatsWhyKind.copyRejectedByMime => statsWhyCopyRejected,
            StatsWhyKind.serverReencoding => statsWhyServerReencoding,
            StatsWhyKind.browserReencodes => statsWhyBrowserReencodes,
            StatsWhyKind.switchedEarlier => statsWhySwitchedEarlier,
            StatsWhyKind.recentStall => statsWhyRecentStall,
          },
        StatsWhyCapped(:final rung) => statsWhyQualityCapped(qualityName(rung)),
        StatsWhyRemembered(:final codec) => statsWhyRememberedFailure(codec),
        StatsWhyStalled(:final minutes) => statsWhyStalledMinutes(minutes),
        StatsWhyFallback(:final reason) => fallbackMessage(reason),
      };

  /// The Playing row's quality: the choice, and for Auto what it resolved to.
  String statsQualityText(StatsQuality quality) {
    final selected = quality.selected;
    if (!selected.isAuto) return qualityName(selected);
    final effective = quality.effective;
    return effective == null
        ? qualityAuto
        : qualityAutoRung(qualityName(effective));
  }

  /// A subtitle toast the player raised on its own.
  String subtitleNoticeText(SubtitleNotice notice) => switch (notice) {
        SubtitleNotice.notCarried => subtitleNoticeNotCarried,
        SubtitleNotice.imageOnlyAtOriginal => subtitleNoticeImageOnlyAtOriginal,
        SubtitleNotice.loadFailed => subtitleNoticeLoadFailed,
        SubtitleNotice.preparingImage => subtitleNoticePreparingImage,
      };

  /// The toast for a subtitle delay nudge or save.
  String subtitleDelayNoticeText(SubtitleDelayNotice notice) {
    final delay = subtitleDelayAmount(
      '${notice.totalMs >= 0 ? '+' : ''}${notice.totalMs}',
    );
    return switch (notice.kind) {
      SubtitleDelayNoticeKind.adjusted => subtitleDelayToastAdjusted(delay),
      SubtitleDelayNoticeKind.adjustedAfterSave =>
        subtitleDelayToastAfterSave(delay),
      SubtitleDelayNoticeKind.saved => subtitleDelayToastSaved,
      SubtitleDelayNoticeKind.savedAppliesLater => subtitleDelayToastSavedLater,
      SubtitleDelayNoticeKind.saveFailed => subtitleDelaySaveFailed,
    };
  }

  /// Why a subtitle search or download did not happen.
  String subtitleIssueText(SubtitleIssue issue) => switch (issue) {
        SubtitleIssue.searchMydiaOnly => subtitleIssueSearchMydiaOnly,
        SubtitleIssue.downloadMydiaOnly => subtitleIssueDownloadMydiaOnly,
        SubtitleIssue.searchOffline => subtitleIssueSearchOffline,
        SubtitleIssue.downloadOffline => subtitleIssueDownloadOffline,
        SubtitleIssue.searchUnreachable => subtitleIssueSearchUnreachable,
        SubtitleIssue.searchFailed => subtitleSearchFailed,
        SubtitleIssue.downloadFailed => subtitleDownloadFailed,
      };
}

/// ISO 639-1, 639-2/T and 639-2/B codes to the two letter key the
/// `languageNameByCode` message selects on.
const _languageKeys = <String, String>{
  'eng': 'en',
  'en': 'en',
  'spa': 'es',
  'es': 'es',
  'fre': 'fr',
  'fra': 'fr',
  'fr': 'fr',
  'ger': 'de',
  'deu': 'de',
  'de': 'de',
  'ita': 'it',
  'it': 'it',
  'por': 'pt',
  'pt': 'pt',
  'rus': 'ru',
  'ru': 'ru',
  'jpn': 'ja',
  'ja': 'ja',
  'kor': 'ko',
  'ko': 'ko',
  'chi': 'zh',
  'zho': 'zh',
  'zh': 'zh',
  'ara': 'ar',
  'ar': 'ar',
  'hin': 'hi',
  'hi': 'hi',
  'nld': 'nl',
  'dut': 'nl',
  'nl': 'nl',
  'swe': 'sv',
  'sv': 'sv',
  'nor': 'no',
  'no': 'no',
  'dan': 'da',
  'da': 'da',
  'fin': 'fi',
  'fi': 'fi',
  'pol': 'pl',
  'pl': 'pl',
  'tur': 'tr',
  'tr': 'tr',
};
