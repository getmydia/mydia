import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:player/core/connection/connection_summary.dart';
import 'package:player/core/downloads/download_notification_text.dart';
import 'package:player/core/logging/log_uploader.dart';
import 'package:player/core/playback/loading_step.dart';
import 'package:player/core/playback/playback_memory.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/playback/stats/playback_stats.dart';
import 'package:player/core/playback/stats/stats_report.dart';
import 'package:player/core/player/fullscreen/fullscreen_failure.dart';
import 'package:player/core/player/subtitle_size.dart';
import 'package:player/core/router/push_route.dart';
import 'package:player/core/theme/glass_material.dart';
import 'package:player/core/theme/theme_preset.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/core/update/update_track.dart';
import 'package:player/domain/models/audio_track.dart';
import 'package:player/domain/models/media_segment.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/domain/models/remote_device.dart';
import 'package:player/domain/models/storage_settings.dart';
import 'package:player/domain/models/subtitle_search_outcome.dart';
import 'package:player/domain/models/subtitle_track.dart';
import 'package:player/domain/navigation/media_filter.dart';
import 'package:player/domain/navigation/nav_destination.dart';
import 'package:player/domain/navigation/source_nav.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/l10n/formatters.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/login/login_failure.dart';
import 'package:player/presentation/screens/player/session/playback_problem.dart';
import 'package:player/presentation/screens/player/subtitle_track_builder.dart'
    show SubtitleDelayNotice, SubtitleDelayNoticeKind, SubtitleNotice;

import '../presentation/screens/calendar/calendar_test_items.dart';

Future<AppLocalizations> l10n(String tag) =>
    AppLocalizations.delegate.load(Locale.fromSubtags(
      languageCode: tag.split('_').first,
      countryCode: tag.contains('_') ? tag.split('_').last : null,
    ));

void main() {
  final now = DateTime(2026, 10, 25, 12);

  setUpAll(() => initializeDateFormatting());

  group('calendar dates', () {
    final monday = DateTime(2026, 10, 26);
    final october = DateTime(2026, 10);

    test('en matches the old hand-written names', () async {
      final en = await l10n('en');
      expect(en.weekdayShort(monday), 'Mon');
      expect(en.weekdayShort(DateTime(2026, 10, 25)), 'Sun');
      expect(en.weekdayNarrow(monday), 'M');
      expect(en.monthName(october), 'October');
      expect(en.monthYear(october), 'October 2026');
      expect(en.monthLabel(DateTime(2026, 11), DateTime(2026, 10, 16)),
          'November');
      expect(en.monthLabel(DateTime(2027, 1), DateTime(2026, 10, 16)),
          'January 2027');
    });

    test('es and pt_BR differ from en', () async {
      final en = await l10n('en');
      for (final tag in ['es', 'pt_BR']) {
        final loc = await l10n(tag);
        expect(loc.weekdayShort(monday), isNot(en.weekdayShort(monday)));
        expect(loc.monthName(october), isNot(en.monthName(october)));
        expect(loc.monthYear(october), isNot(en.monthYear(october)));
        expect(loc.monthYear(october), contains('2026'));
      }
    });

    test('numbering is the episode code, or the Movie word for a movie',
        () async {
      final en = await l10n('en');
      final episode = calendarEntry('1', DateTime(2026, 10, 16),
          title: 'The Tide Ledger', season: 2, episode: 5);
      final movie = calendarEntry('2', DateTime(2026, 10, 16),
          kind: ItemKind.movie, title: 'Brasswork');
      expect(en.calendarNumbering(episode), 'S02E05');
      expect(en.calendarSubtitle(episode), 'S02E05 · The Tide Ledger');
      expect(en.calendarNumbering(movie), 'Movie');
      expect(en.calendarSubtitle(movie), 'Movie');
      expect((await l10n('es')).calendarNumbering(movie), isNot('Movie'));
    });
  });

  group('relativeTime', () {
    test('en thresholds match the old formatter', () async {
      final en = await l10n('en');
      String at(Duration d) => en.relativeTime(now.subtract(d), now: now);
      expect(at(const Duration(seconds: 30)), 'Just now');
      expect(at(const Duration(minutes: 1)), '1 minute ago');
      expect(at(const Duration(minutes: 42)), '42 minutes ago');
      expect(at(const Duration(minutes: 59)), '59 minutes ago');
      expect(at(const Duration(hours: 1)), '1 hour ago');
      expect(at(const Duration(hours: 3)), '3 hours ago');
      expect(at(const Duration(days: 1)), '1 day ago');
      expect(at(const Duration(days: 2)), '2 days ago');
      expect(at(const Duration(days: 29)), '29 days ago');
      expect(at(const Duration(days: 30)), '1 month ago');
      expect(at(const Duration(days: 90)), '3 months ago');
      expect(at(const Duration(days: 365)), '1 year ago');
      expect(at(const Duration(days: 800)), '2 years ago');
    });

    test('a future timestamp is clamped to just now', () async {
      final en = await l10n('en');
      expect(
        en.relativeTime(now.add(const Duration(minutes: 5)), now: now),
        'Just now',
      );
    });

    test('es and pt_BR translate', () async {
      final es = await l10n('es');
      final pt = await l10n('pt_BR');
      final t = now.subtract(const Duration(hours: 2));
      expect(es.relativeTime(t, now: now), isNot('2 hours ago'));
      expect(pt.relativeTime(t, now: now), isNot('2 hours ago'));
      expect(es.relativeTime(t, now: now), contains('2'));
    });
  });

  test('remainingTime', () async {
    final en = await l10n('en');
    expect(en.remainingTime(const Duration(seconds: 42)), '42s left');
    expect(en.remainingTime(const Duration(seconds: 61)), '2m left');
    expect(en.remainingTime(const Duration(minutes: 125)), '2h 5m left');
  });

  test('runtime', () async {
    final en = await l10n('en');
    expect(en.runtime(const Duration(minutes: 45)), '45m');
    expect(en.runtime(const Duration(minutes: 120)), '2h');
    expect(en.runtime(const Duration(minutes: 80)), '1h 20m');
    expect(en.runtime(const Duration(minutes: 146)), '2h 26m');
  });

  test('watchedDate elides the current year', () async {
    final en = await l10n('en');
    final aug = DateTime(2026, 8, 4);
    expect(en.watchedDate(DateTime(2026, 8, 2, 12), aug), 'Aug 2');
    expect(en.watchedDate(DateTime(2025, 8, 2, 12), aug), 'Aug 2, 2025');
    expect(en.watchedDate(DateTime(2026, 10, 5), now), 'Oct 5');
    expect(en.watchedDate(DateTime(2024, 3, 9), now), 'Mar 9, 2024');
    final es = await l10n('es');
    expect(es.watchedDate(DateTime(2026, 10, 5), now), isNot('Oct 5'));
  });

  test('remoteDeviceStatus', () async {
    final en = await l10n('en');
    expect(en.remoteDeviceStatus(RemoteDeviceStatus.revoked), 'Revoked');
    expect(
        en.remoteDeviceStatus(RemoteDeviceStatus.neverActive), 'Never active');
    expect(en.remoteDeviceStatus(RemoteDeviceStatus.active), 'Active');
    expect(en.remoteDeviceStatus(RemoteDeviceStatus.inactive), 'Inactive');
  });

  test('enum names keep their English labels', () async {
    final en = await l10n('en');
    expect(en.themePresetName(ThemePreset.projectionBooth), 'Projection Booth');
    expect(en.themePresetName(ThemePreset.oledBlack), 'OLED Black');
    expect(en.themePresetName(ThemePreset.slate), 'Slate');
    expect(en.themePresetName(ThemePreset.macos), 'macOS');
    expect(en.glassMaterialName(GlassMaterial.liquid), 'Liquid Glass');
    expect(en.glassMaterialName(GlassMaterial.frosted), 'Frosted');
    expect(en.subtitleSizeName(SubtitleSize.small), 'Small');
    expect(en.subtitleSizeName(SubtitleSize.medium), 'Medium');
    expect(en.subtitleSizeName(SubtitleSize.large), 'Large');
    expect(en.subtitleSizeName(SubtitleSize.extraLarge), 'Extra large');
    expect(en.updateTrackName(UpdateTrack.stable), 'Stable');
    expect(en.updateTrackName(UpdateTrack.beta), 'Beta');
    expect(en.updateTrackName(UpdateTrack.dev), 'Dev');
    expect(en.updateTrackDescription(UpdateTrack.stable),
        'Released builds. The default.');
    expect(en.updateTrackDescription(UpdateTrack.beta),
        'Prerelease builds, a few weeks ahead of stable and less tested.');
    expect(en.updateTrackDescription(UpdateTrack.dev),
        'Builds straight from development, published when a maintainer asks for one. Expect rough edges.');
    expect(en.qualityName(QualityRung.auto), 'Auto');
    expect(en.qualityName(QualityRung.original), 'Original');
    expect(
        en.qualityName(const QualityRung(label: '720p', height: 720)), '720p');
  });

  test('fullscreenFailureMessage distinguishes exit from enter', () async {
    final en = await l10n('en');
    for (final cause in FullscreenFailureCause.values) {
      final exit = cause == FullscreenFailureCause.documentExitRejected ||
          cause == FullscreenFailureCause.videoExitFailed;
      expect(en.fullscreenFailureMessage(FullscreenFailure(cause)),
          exit ? 'Could not exit fullscreen' : 'Could not enter fullscreen');
    }
  });

  test('updateErrorMessage formats a track that is not published', () async {
    final en = await l10n('en');
    expect(
      en.updateErrorMessage(const UpdateState(
          trackNotPublished: TrackNotPublished(UpdateTrack.dev))),
      'Dev builds are not published for this platform yet.',
    );
    expect(
      en.updateErrorMessage(const UpdateState(
          trackNotPublished: TrackNotPublished(UpdateTrack.dev, macos: true))),
      'Dev builds are not published for macOS yet.',
    );
    expect(en.updateErrorMessage(const UpdateState(error: 'boom')), 'boom');
    expect(en.updateErrorMessage(const UpdateState()), isNull);
  });

  test('enum names translate', () async {
    for (final tag in ['es', 'pt_BR']) {
      final t = await l10n(tag);
      expect(t.updateTrackName(UpdateTrack.stable), isNot('Stable'));
      expect(t.subtitleSizeName(SubtitleSize.large), isNot('Large'));
      expect(t.glassMaterialName(GlassMaterial.frosted), isNot('Frosted'));
      expect(
          t.fullscreenFailureMessage(
              const FullscreenFailure(FullscreenFailureCause.noVideoElement)),
          isNot('Could not enter fullscreen'));
    }
  });

  group('quality sentences', () {
    const r720 = QualityRung(label: '720p', height: 720, maxBitrateKbps: 4000);
    const r1080 =
        QualityRung(label: '1080p', height: 1080, maxBitrateKbps: 8000);

    test('autoDeliverySubtitle keeps its English text', () async {
      final en = await l10n('en');
      expect(
        en.autoDeliverySubtitle(
            const DirectPlayPlan(reason: PlanReason.directPlayAccepted)),
        'Auto · Direct Play',
      );
      expect(
        en.autoDeliverySubtitle(const HlsPlan(
          strategy: HlsStrategy.copy,
          rung: QualityRung.original,
          adaptive: false,
          reason: PlanReason.copyAccepted,
        )),
        'Auto · Original, no re-encoding',
      );
      expect(
        en.autoDeliverySubtitle(const HlsPlan(
          strategy: HlsStrategy.transcode,
          rung: QualityRung.original,
          adaptive: true,
          reason: PlanReason.noDirectPlayCandidate,
        )),
        'Auto · Original, re-encoding required',
      );
      expect(
        en.autoDeliverySubtitle(
          const HlsPlan(
            strategy: HlsStrategy.transcode,
            rung: r1080,
            adaptive: true,
            reason: PlanReason.noDirectPlayCandidate,
          ),
          effective: r720,
        ),
        'Auto · 720p',
      );
    });

    test('clamp note and preference subtitle', () async {
      final en = await l10n('en');
      expect(en.qualityClampNote(en.qualityName(r720)),
          'Limited to 720p by your connection');
      expect(en.qualityAutoPreference, 'Adapts to your connection');
      final es = await l10n('es');
      expect(es.qualityClampNote('720p'), isNot(contains('Limited')));
      expect(es.qualityAutoRung('720p'), contains('720p'));
    });
  });

  group('loginFailure', () {
    test('every kind has text in every locale and server text is verbatim',
        () async {
      for (final tag in ['en', 'es', 'pt_BR']) {
        final loc = await l10n(tag);
        for (final kind in LoginFailureKind.values) {
          expect(loc.loginFailure(LoginFailureOfKind(kind)), isNotEmpty);
        }
        expect(loc.loginFailure(const LoginFailureFromServer('Nope, said it')),
            'Nope, said it');
      }
      final en = await l10n('en');
      expect(
          en.loginFailure(
              const LoginFailureOfKind(LoginFailureKind.invalidCode)),
          'Invalid code');
      final es = await l10n('es');
      expect(
          es.loginFailure(
              const LoginFailureOfKind(LoginFailureKind.cannotConnect)),
          isNot(contains('Cannot')));
    });
  });

  group('navigation and library names', () {
    test('every builtin destination has a name that is not its id', () async {
      for (final tag in ['en', 'es', 'pt_BR']) {
        final loc = await l10n(tag);
        for (final d in builtinDestinations) {
          final name = loc.navDestinationLabel(d);
          expect(name, isNotEmpty, reason: '$tag ${d.id}');
          expect(name, isNot(d.id), reason: '$tag ${d.id}');
        }
      }
    });

    test('a saved filter keeps the words the viewer typed', () async {
      final es = await l10n('es');
      const filter = FilterDestination(
        id: 'f1',
        label: 'Unwatched Anime',
        filter: MediaFilter.allMovies,
      );
      expect(es.navDestinationLabel(filter), 'Unwatched Anime');
    });

    test('entries: a library keeps its server name, builtins are worded',
        () async {
      final es = await l10n('es');
      const icon = Icons.circle;
      expect(
        es.navEntryLabel(const SourceNavEntry(
            id: 'library-1',
            label: 'Kids',
            icon: icon,
            selectedIcon: icon,
            route: '/x')),
        'Kids',
      );
      expect(
        es.navEntryLabel(const SourceNavEntry(
            id: 'library-2',
            libraryKind: LibraryKind.videos,
            icon: icon,
            selectedIcon: icon,
            route: '/x')),
        'Vídeos',
      );
      expect(
        es.navEntryTabLabel(const SourceNavEntry(
            id: 'shows',
            shortLabel: true,
            icon: icon,
            selectedIcon: icon,
            route: '/x')),
        'Series',
      );
    });

    test('sort and filter names exist in every language', () async {
      for (final tag in ['en', 'es', 'pt_BR']) {
        final loc = await l10n(tag);
        for (final name in SortName.values) {
          expect(loc.sortName(name), isNotEmpty, reason: '$tag $name');
        }
        for (final name in FilterName.values) {
          expect(loc.filterOptionName(FilterOption(id: 'x', name: name)),
              isNotEmpty);
        }
        for (final category in MediaCategoryFilter.values) {
          expect(loc.categoryFilterName(category), isNotEmpty);
        }
      }
      final en = await l10n('en');
      expect(en.sortName(SortName.recentlyAdded), 'Recently added');
    });
  });

  group('playback stats', () {
    test('values read the way the panel always drew them in English', () async {
      final en = await l10n('en');
      expect(
          en.statsValue(const StatsBufferValue(Duration(milliseconds: 18400))),
          '18.4 s ahead');
      expect(en.statsValue(const StatsFramesValue(dropped: 3, total: 40)),
          '3 dropped - 40 total');
      expect(en.statsValue(const StatsDecoderValue('h264', true)),
          'h264 hardware');
      expect(en.statsValue(const StatsDecoderValue('h264', null)), 'h264');
      expect(en.statsModeName(PlaybackMode.transcode), 'Transcode');
    });

    test('the buffer uses the language decimal separator', () async {
      final es = await l10n('es');
      expect(
          es.statsValue(const StatsBufferValue(Duration(milliseconds: 18400))),
          contains('18,4'));
    });

    test('every row and mode has a label in every language', () async {
      for (final tag in ['en', 'es', 'pt_BR']) {
        final loc = await l10n(tag);
        for (final id in StatsRowId.values) {
          expect(loc.statsRowLabel(id), isNotEmpty);
        }
        for (final mode in PlaybackMode.values) {
          expect(loc.statsModeName(mode), isNotEmpty);
          expect(loc.statsPill(mode), isNotEmpty);
        }
      }
    });
  });

  group('core and domain display text', () {
    test('track names: its own title, else the language', () async {
      final es = await l10n('es');
      expect(es.audioTrackName(const AudioTrack(id: '1', language: 'spa')),
          'Español');
      expect(
          es.audioTrackName(
              const AudioTrack(id: '1', language: 'eng', title: 'Commentary')),
          'Commentary');
      expect(es.subtitleTrackName(const SubtitleTrack(id: '2', language: 'xx')),
          'XX');
    });

    test('connection summaries name every kind in every language', () async {
      for (final tag in ['en', 'es', 'pt_BR']) {
        final loc = await l10n(tag);
        for (final kind in ConnectionKind.values) {
          final summary =
              ConnectionSummary(kind: kind, tone: ConnectionTone.good);
          expect(loc.connectionLabel(summary), isNotEmpty);
          expect(loc.connectionDetail(summary), isNotEmpty);
        }
      }
    });

    test('segment, push and storage names exist in every language', () async {
      for (final tag in ['en', 'es', 'pt_BR']) {
        final loc = await l10n(tag);
        for (final type in SegmentType.values) {
          expect(loc.segmentSkipLabel(type), isNotEmpty);
        }
        expect(loc.pushOutcomeMessage(PushOutcome.blockedByPlayer), isNotEmpty);
        expect(loc.pushOutcomeMessage(PushOutcome.blockedByForm), isNotEmpty);
        expect(loc.pushOutcomeMessage(PushOutcome.pushed), isNull);
        for (final policy in CleanupPolicy.values) {
          expect(loc.cleanupPolicyName(policy), isNotEmpty);
        }
      }
    });

    test('the downloads title counts items', () async {
      final en = await l10n('en');
      expect(en.downloadNotificationTitle(1), 'Downloading');
      expect(en.downloadNotificationTitle(3), 'Downloading 3 items');
      expect(
          en.downloadNotificationLine(const NotificationProgress('Quill', 40)),
          'Quill - 40%');
    });

    test('update notices and log upload failures are worded in every language',
        () async {
      for (final tag in ['en', 'es', 'pt_BR']) {
        final loc = await l10n(tag);
        for (final notice in UpdateNotice.values) {
          expect(loc.updateNoticeText(notice), isNotEmpty);
        }
        for (final failure in LogUploadFailure.values) {
          expect(loc.logUploadFailure(LogUploadException(failure, status: 502)),
              isNotEmpty);
        }
      }
      final en = await l10n('en');
      expect(
          en.logUploadFailure(const LogUploadException(
              LogUploadFailure.relayHttp,
              status: 502)),
          'The relay answered HTTP 502');
    });

    test('an unnamed video library is Videos, and Scenes only for Stash',
        () async {
      final en = await l10n('en');
      const ref = LibraryRef(sourceId: SourceId('s'), id: '1');
      expect(en.libraryTitle(const Library(ref: ref, kind: LibraryKind.videos)),
          'Videos');
      expect(
          en.libraryTitle(
              const Library(ref: ref, kind: LibraryKind.videos, scenes: true)),
          'Scenes');
    });
  });

  group('player screen text', () {
    test('every loading step, fallback and why reads in every language',
        () async {
      for (final tag in const ['en', 'es', 'pt_BR']) {
        final loc = await l10n(tag);
        for (final kind in LoadingStepKind.values) {
          expect(
            loc.loadingStepText(
                LoadingStep(kind, percent: 33, attempt: 2, maxAttempts: 20)),
            isNotEmpty,
          );
        }
        for (final reason in FailureReason.values) {
          expect(loc.fallbackMessage(reason), isNotEmpty);
          expect(loc.statsWhyText(StatsWhyFallback(reason)), isNotEmpty);
        }
        for (final kind in StatsWhyKind.values) {
          expect(loc.statsWhyText(StatsWhyPlain(kind)), isNotEmpty);
        }
        for (final notice in SubtitleNotice.values) {
          expect(loc.subtitleNoticeText(notice), isNotEmpty);
        }
        for (final kind in SubtitleDelayNoticeKind.values) {
          expect(
              loc.subtitleDelayNoticeText(
                  SubtitleDelayNotice(kind, totalMs: 100)),
              isNotEmpty);
        }
        for (final issue in SubtitleIssue.values) {
          expect(loc.subtitleIssueText(issue), isNotEmpty);
        }
        for (final issue in PlaybackIssue.values) {
          expect(loc.playbackIssueText(issue), isNotEmpty);
        }
      }
    });

    test('the loading step carries its numbers', () async {
      final en = await l10n('en');
      expect(
          en.loadingStepText(
              const LoadingStep(LoadingStepKind.preparingStream, percent: 33)),
          'Preparing stream... 33%');
      expect(
          en.loadingStepText(const LoadingStep(
              LoadingStepKind.startingTranscode,
              attempt: 2,
              maxAttempts: 20)),
          'Starting transcoding... (2/20)');
    });

    test('the Why row words each reason', () async {
      final en = await l10n('en');
      const capped = QualityRung(label: '720p', height: 720);
      expect(en.statsWhyText(const StatsWhyCapped(capped)),
          'Quality capped to 720p');
      expect(en.statsWhyText(const StatsWhyCapped(QualityRung.original)),
          'Quality capped to Original');
      expect(en.statsWhyText(const StatsWhyRemembered('hevc')),
          'Remembered decode failure on hevc');
      expect(en.statsWhyText(const StatsWhyStalled(12)),
          'Stalled on this connection 12 min ago');
      expect(en.statsWhyText(const StatsWhyFallback(FailureReason.bandwidth)),
          'Switched to transcoding for your connection');
      expect(
          en.fallbackMessage(FailureReason.decodeFailed),
          "Switched to transcoding: your device can't play this file "
          'directly');
    });

    test('the Playing quality names Auto and what it resolved to', () async {
      final en = await l10n('en');
      const r720 = QualityRung(label: '720p', height: 720);
      expect(
          en.statsQualityText(const StatsQuality(selected: QualityRung.auto)),
          'Auto');
      expect(
          en.statsQualityText(
              const StatsQuality(selected: QualityRung.auto, effective: r720)),
          'Auto · 720p');
      expect(
          en.statsQualityText(
              const StatsQuality(selected: QualityRung.original)),
          'Original');
    });

    test('the link row counts peers with a plural', () async {
      final en = await l10n('en');
      expect(en.statsLinkPeers('direct', 1), 'direct - 1 peer');
      expect(en.statsLinkPeers('direct', 3), 'direct - 3 peers');
    });

    test('subtitle delay toasts show the signed delay', () async {
      final en = await l10n('en');
      expect(
          en.subtitleDelayNoticeText(const SubtitleDelayNotice(
              SubtitleDelayNoticeKind.adjusted,
              totalMs: 100)),
          'Subtitle delay +100 ms');
      expect(
          en.subtitleDelayNoticeText(const SubtitleDelayNotice(
              SubtitleDelayNoticeKind.adjustedAfterSave,
              totalMs: -200)),
          'Subtitle delay will be -200 ms after Save');
    });

    test('a playback problem is the app\'s sentence or the server\'s text',
        () async {
      final en = await l10n('en');
      expect(
          en.playbackProblemText(
              const PlaybackProblem(PlaybackIssue.noPlayableFile)),
          'This item has no playable file on the server.');
      expect(en.playbackProblemText(const PlaybackProblem.fromText('Nope')),
          'Nope');
    });
  });
}
