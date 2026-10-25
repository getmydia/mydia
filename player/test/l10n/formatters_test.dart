import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:player/core/playback/playback_plan.dart';
import 'package:player/core/player/fullscreen/fullscreen_failure.dart';
import 'package:player/core/player/subtitle_size.dart';
import 'package:player/core/theme/glass_material.dart';
import 'package:player/core/theme/theme_preset.dart';
import 'package:player/core/update/update_provider.dart';
import 'package:player/core/update/update_track.dart';
import 'package:player/domain/models/quality_rung.dart';
import 'package:player/domain/models/remote_device.dart';
import 'package:player/l10n/formatters.dart';
import 'package:player/l10n/gen/app_localizations.dart';

Future<AppLocalizations> l10n(String tag) =>
    AppLocalizations.delegate.load(Locale.fromSubtags(
      languageCode: tag.split('_').first,
      countryCode: tag.contains('_') ? tag.split('_').last : null,
    ));

void main() {
  final now = DateTime(2026, 10, 25, 12);

  setUpAll(() => initializeDateFormatting());

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
}
