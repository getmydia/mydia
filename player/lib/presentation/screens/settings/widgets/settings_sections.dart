/// Settings content shared by the mobile settings screen and the desktop
/// settings dialog. Each piece reads its own providers, so either host can
/// place it without wiring.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/build_channel.dart';
import '../../../../core/remote/node_registration_providers.dart';
import '../../../../core/remote/registration_status.dart';
import '../../../../core/remote/remote_control_settings.dart';
import '../../../../core/settings/stats_overlay_setting.dart';
import '../../../../core/theme/glass_material.dart';
import '../../../../core/theme/palette.dart';
import '../../../../core/update/update_backend.dart';
import '../../../../core/update/update_provider.dart';
import '../../../../domain/models/available_update.dart';
import '../../../../domain/models/quality_delivery_subtitle.dart';
import '../../../../domain/models/quality_rung.dart';
import '../../../../domain/models/user_settings.dart';
import '../../../../l10n/l10n.dart';
import '../../../widgets/hls_quality_selector.dart';
import '../../../widgets/glass/glass_dialog.dart';
import '../settings_controller.dart';
import 'glass_material_row.dart';
import 'language_row.dart';
import 'settings_row.dart';
import 'settings_section.dart';
import 'subtitle_size_row.dart';
import 'theme_preset_row.dart';
import 'track_picker_row.dart';
import 'update_card.dart';

/// Default quality, skipping, the stats overlay and, in the desktop dialog,
/// whether this device can be controlled.
class PlaybackSettingsSection extends ConsumerWidget {
  const PlaybackSettingsSection({
    super.key,
    required this.settings,
    required this.failed,
    this.includeRemoteControl = false,
  });

  final UserSettings? settings;
  final bool failed;

  /// The dialog has no Manage section, so the remote-control rows join
  /// Playback there. The mobile screen keeps them under Manage.
  final bool includeRemoteControl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Promote the field to a local so null checks bind; Dart does not promote
    // instance fields.
    final current = settings;
    final quality = current == null
        ? QualityRung.auto
        : QualityRung.fromStorageKey(current.defaultQuality) ??
            QualityRung.auto;
    final l10n = context.l10n;

    return SettingsSection(
      label: l10n.settingsPlayback,
      children: [
        SettingsRow.navigation(
          key: const Key('default-quality-row'),
          icon: Icons.hd,
          title: l10n.settingsDefaultQualityTitle,
          subtitle: l10n.settingsDefaultQualitySubtitle,
          value: current == null ? null : l10n.qualityName(quality),
          onTap: current == null
              ? null
              : () => _pickQuality(context, ref, quality),
        ),
        SettingsRow.toggle(
          key: const Key('auto-skip-segments-switch'),
          icon: Icons.fast_forward,
          title: l10n.settingsAutoSkipTitle,
          subtitle: l10n.settingsAutoSkipSubtitle,
          value: current?.autoSkipSegments ?? false,
          onChanged: current == null
              ? null
              : (value) => ref
                  .read(settingsControllerProvider.notifier)
                  .setAutoSkipSegments(value),
        ),
        const SubtitleSizeSettingsRow(),
        Consumer(
          builder: (context, ref, _) {
            final enabled =
                ref.watch(statsOverlayEnabledProvider).value ?? false;
            return SettingsRow.toggle(
              key: const Key('stats-overlay-switch'),
              icon: Icons.speed,
              title: l10n.settingsStatsOverlayTitle,
              subtitle: l10n.settingsStatsOverlaySubtitle,
              value: enabled,
              onChanged: (value) =>
                  ref.read(statsOverlayEnabledProvider.notifier).set(value),
            );
          },
        ),
        if (includeRemoteControl) ...remoteControlRows(context, ref),
        if (failed)
          SettingsRow.action(
            key: const Key('settings-retry-row'),
            icon: Icons.error_outline,
            title: l10n.settingsPreferencesLoadFailedTitle,
            subtitle: l10n.settingsPreferencesLoadFailedSubtitle,
            trailing: Text(l10n.commonRetry),
            onTap: () => ref.invalidate(settingsControllerProvider),
          ),
      ],
    );
  }

  Future<void> _pickQuality(
    BuildContext context,
    WidgetRef ref,
    QualityRung current,
  ) async {
    // The full ladder, not a per-file one: this is a standing preference set
    // outside playback, where there is no source to derive against. Playback
    // narrows it per file and falls back to Auto if the stored rung would
    // upscale.
    final picked = await showQualityPicker(
      context,
      [QualityRung.auto, ...deriveQualityLadder(sourceHeight: 2160)],
      current,
      // A standing preference has no streaming candidates to derive delivery
      // from, so both open rows keep a neutral subtitle.
      autoSubtitle: context.l10n.qualityAutoPreference,
      originalSubtitle: kOriginalPreferenceSubtitle,
    );

    if (picked == null || !context.mounted) return;
    await ref
        .read(settingsControllerProvider.notifier)
        .setDefaultQuality(picked.storageKey);
  }
}

/// The remote-control switch and, after a failed registration, its retry.
///
/// Rows rather than a widget: [SettingsCard] draws the dividers between its
/// direct children, so a wrapper holding two rows would lose the one between
/// them.
List<Widget> remoteControlRows(BuildContext context, WidgetRef ref) {
  final controllableEnabled = ref.watch(remoteControlEnabledProvider).value;
  final registration = ref.watch(nodeRegistrationSummaryProvider);
  final l10n = context.l10n;
  return [
    SettingsRow.toggle(
      key: const Key('remote-control-enabled-switch'),
      icon: Icons.settings_remote,
      title: l10n.settingsRemoteControlTitle,
      subtitle: registration.describe(),
      value: controllableEnabled ?? true,
      onChanged: controllableEnabled == null
          ? null
          : (value) => _setControllable(ref, value),
    ),
    if (registration is RegistrationFailed)
      SettingsRow.action(
        key: const Key('remote-control-retry-row'),
        icon: Icons.refresh,
        title: l10n.settingsRetryRegistrationTitle,
        subtitle: l10n.settingsRetryRegistrationSubtitle,
        onTap: () => ref.read(nodeRegistrationsProvider.notifier).retryAll(),
      ),
  ];
}

/// Persists the opt-in/opt-out and invalidates [remoteControlEnabledProvider]
/// so the switch reflects it immediately. This only ever affects whether
/// this device *answers* as a target; it never touches pairing or this
/// device's own ability to control others.
///
/// Runs from a switch callback that nothing awaits, so a failure here —
/// `remoteControlSettingsProvider` failing to resolve, or the Hive write
/// itself throwing — has no caller to escape to; left unguarded it would
/// surface as an unhandled async error. Caught and logged instead.
/// [remoteControlEnabledProvider] is still invalidated afterward either
/// way: the switch is driven entirely by that provider's value, with no
/// optimistic local state, so re-reading it after a failed write just
/// reconfirms the unchanged, actually-persisted value rather than leaving
/// the switch out of sync with storage.
Future<void> _setControllable(WidgetRef ref, bool value) async {
  try {
    final settings = await ref.read(remoteControlSettingsProvider.future);
    await settings.setControllable(value);
  } catch (e) {
    debugPrint('[Settings] Could not save remote-control setting: $e');
  }
  ref.invalidate(remoteControlEnabledProvider);
}

/// The release track and the manual update check.
List<Widget> updateRows(BuildContext context, WidgetRef ref) {
  final updateState = ref.watch(updateProvider);
  final l10n = context.l10n;
  return [
    const UpdateTrackSection(),
    if (updateState.manualCheck != ManualCheckBehaviour.unavailable)
      SettingsRow.action(
        key: const Key('check-for-updates-row'),
        icon: Icons.refresh,
        title: updateState.manualCheck == ManualCheckBehaviour.checksAndInstalls
            ? l10n.settingsCheckAndInstallUpdates
            : l10n.settingsCheckForUpdates,
        subtitle: updateCheckSubtitle(
          l10n,
          behaviour: updateState.manualCheck,
          update: updateState.availableUpdate,
        ),
        // isChecking covers the checksOnly/unavailable path (_refresh);
        // isApplying covers checksAndInstalls (requestUpdate). The
        // Flatpak row's press goes straight to requestUpdate, so without
        // isApplying here a multi-second check-and-install transaction
        // shows no feedback at all.
        trailing: (updateState.isChecking || updateState.isApplying)
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
        onTap: (updateState.isChecking || updateState.isApplying)
            ? null
            : () => _check(context, ref),
      ),
  ];
}

/// A press on a check-and-install row installs, so it asks first. There is
/// no version to preview, because the portal reports commits, so the dialog
/// says what the press does rather than what it will fetch.
Future<void> _check(BuildContext context, WidgetRef ref) async {
  final state = ref.read(updateProvider);

  if (state.manualCheck == ManualCheckBehaviour.checksAndInstalls) {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l10n = ctx.l10n;
        return GlassDialog(
          title: Text(l10n.settingsCheckForUpdates),
          content: Text(l10n.settingsCheckForUpdatesConfirm),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.commonContinue),
            ),
          ],
        );
      },
    );
    if (proceed != true) return;
  }

  await ref.read(updateProvider.notifier).checkForUpdate();
}

/// The desktop dialog's About pane: what is running, and getting a newer one.
class AboutSettingsSection extends ConsumerWidget {
  const AboutSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(updateProvider).currentVersion;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
          child: Text(
            key: const Key('about-app-name'),
            version.isEmpty
                ? BuildChannel.current.appName
                : '${BuildChannel.current.appName} $version',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const UpdateCard(),
        SettingsSection(
          label: context.l10n.settingsUpdatesSection,
          children: updateRows(context, ref),
        ),
      ],
    );
  }
}

/// Subtitle for the check-for-updates row.
///
/// Sparkle needs its own string, and the Flatpak row cannot promise a version
/// because the portal reports commits rather than versions.
@visibleForTesting
String updateCheckSubtitle(
  AppLocalizations l10n, {
  required ManualCheckBehaviour behaviour,
  required AvailableUpdate? update,
}) {
  if (behaviour == ManualCheckBehaviour.delegatesToSparkle) {
    return l10n.settingsUpdateCheckSparkle;
  }

  final version = update?.version;
  if (version != null) return l10n.settingsUpdateCheckVersionAvailable(version);
  if (update != null) return l10n.settingsUpdateCheckAvailable;

  return behaviour == ManualCheckBehaviour.checksAndInstalls
      ? l10n.settingsUpdateCheckInstallsNewest
      : l10n.settingsUpdateCheckUpToDate;
}

/// The running version, stated once, quietly, at the bottom.
///
/// An empty version renders nothing at all. The hero showed an en dash here,
/// but a footer stating an unknown version is worth less than no footer.
class VersionFooter extends StatelessWidget {
  const VersionFooter({super.key, required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    if (version.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 22, 0, 4),
      child: Text(
        '${BuildChannel.current.appName} $version',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11.5,
          color: context.palette.textDisabled,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Device-level look: the language, the theme preset and the glass material.
class AppearanceSettingsSection extends StatelessWidget {
  const AppearanceSettingsSection({super.key});

  @override
  Widget build(BuildContext context) => SettingsSection(
        label: context.l10n.settingsAppearanceSection,
        children: [
          const LanguageSettingsRow(),
          const ThemePresetSettingsRow(),
          // Conditional here so a TV does not get a divider above nothing.
          if (GlassMaterial.liquid.isAvailableOn(defaultTargetPlatform))
            const GlassMaterialSettingsRow(),
        ],
      );
}
