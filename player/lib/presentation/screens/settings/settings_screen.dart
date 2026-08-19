import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/connection/connection_provider.dart';
import '../../../core/connection/connection_summary.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/p2p/p2p_service.dart';
import '../../../core/player/platform_features.dart';
import '../../../core/theme/colors.dart';
import '../../../core/update/platform_updater.dart';
import '../../../core/update/update_provider.dart';
import '../../../core/update/updaters/macos_updater.dart';
import '../../../domain/models/quality_delivery_subtitle.dart';
import '../../../domain/models/quality_rung.dart';
import '../../../domain/models/user_settings.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/cast_actions.dart';
import '../../widgets/cast_button.dart';
import '../../widgets/connection_tone_color.dart';
import '../../widgets/hls_quality_selector.dart';
import 'settings_controller.dart';
import 'widgets/settings_identity.dart';
import 'widgets/settings_row.dart';
import 'widgets/settings_section.dart';
import 'widgets/update_card.dart';

/// The settings screen.
///
/// Read-only facts live in the hero; everything below it is something you can
/// change or somewhere you can go. The old screen gave a relay URL and a logout
/// button identical tiles, which is what this split fixes.
///
/// Sections fail independently. A preferences read that fails must not take the
/// screen down with it: someone opening settings while something is broken is
/// quite likely there to sign out or collect diagnostics.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsControllerProvider);
    final isP2P = ref.watch(connectionProvider).isP2PMode;
    final p2pStatus = ref.watch(p2pStatusNotifierProvider);
    final currentVersion = ref.watch(updateProvider).currentVersion;

    // Settings shows the calm static backdrop, never a stale title image
    // (plan U5 / AE3).
    publishBackdropSource(ref, BackdropSource.none);

    // Riverpod 3 renamed valueOrNull to value (nullable).
    final settings = settingsAsync.value;
    final summary = ConnectionSummary.from(
      isP2P: isP2P,
      type: p2pStatus.peerConnectionType,
      isInitialized: p2pStatus.isInitialized,
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Settings'),
        // SettingsScreen's app bar is always visible (no desktop
        // suppression), so it carries its own cast affordance instead of
        // the shell's overlay. See AppShell._hasOwnCastButton.
        actions: [
          CastButton(onPressed: () => pickCastDevice(context, ref)),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.symmetric(
          horizontal: MediaQuery.sizeOf(context).width >= 600 ? 26 : 14,
          vertical: 20,
        ),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 660),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SettingsIdentity(
                    username: settings?.username ?? '',
                    serverUrl: settings?.serverUrl ?? '',
                  ),
                  const UpdateCard(),
                  _PlaybackSection(
                    settings: settings,
                    failed: settingsAsync.hasError,
                  ),
                  const SizedBox(height: 18),
                  _ManageSection(connection: summary),
                  const SizedBox(height: 18),
                  _AccountSection(
                    onSignOut: () => _handleSignOut(context, ref),
                  ),
                  _VersionFooter(version: currentVersion),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out'),
        content: const Text('Sign out of this server on this device?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    // One call. AuthStateNotifier.logout() owns the whole teardown and
    // outlives the router redirect that unmounts this screen, which is why
    // the ordering this used to juggle no longer matters. No explicit
    // context.go() needed.
    await ref.read(authStateProvider.notifier).logout();
  }
}

class _PlaybackSection extends ConsumerWidget {
  const _PlaybackSection({required this.settings, required this.failed});

  final UserSettings? settings;
  final bool failed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Promote the field to a local so null checks bind; Dart does not promote
    // instance fields.
    final current = settings;
    final quality = current == null
        ? QualityRung.original
        : QualityRung.fromStorageKey(current.defaultQuality) ??
            QualityRung.original;

    return SettingsSection(
      label: 'Playback',
      children: [
        SettingsRow.navigation(
          key: const Key('default-quality-row'),
          icon: Icons.hd,
          title: 'Default quality',
          subtitle: 'Used when a title has no saved preference',
          value: current == null ? null : quality.label,
          onTap: current == null
              ? null
              : () => _pickQuality(context, ref, quality),
        ),
        SettingsRow.toggle(
          key: const Key('auto-skip-segments-switch'),
          icon: Icons.fast_forward,
          title: 'Skip intros and credits',
          subtitle: 'Off shows a skip button instead',
          value: current?.autoSkipSegments ?? false,
          onChanged: current == null
              ? null
              : (value) => ref
                  .read(settingsControllerProvider.notifier)
                  .setAutoSkipSegments(value),
        ),
        if (failed)
          SettingsRow.action(
            key: const Key('settings-retry-row'),
            icon: Icons.error_outline,
            title: "Couldn't load preferences",
            subtitle: 'Your other settings still work.',
            trailing: const Text('Retry'),
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
    // narrows it per file and falls back to Original if the stored rung would
    // upscale.
    final picked = await showQualityPicker(
      context,
      deriveQualityLadder(sourceHeight: 2160),
      current,
      // The preference picker has no streaming candidates to derive delivery
      // from, so keep a neutral Original subtitle rather than asserting one.
      originalSubtitle: kOriginalPreferenceSubtitle,
    );

    if (picked == null || !context.mounted) return;
    await ref
        .read(settingsControllerProvider.notifier)
        .setDefaultQuality(picked.storageKey);
  }
}

class _ManageSection extends ConsumerWidget {
  const _ManageSection({required this.connection});

  final ConnectionSummary connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updateState = ref.watch(updateProvider);

    return SettingsSection(
      label: 'Manage',
      children: [
        SettingsRow.navigation(
          icon: Icons.devices,
          title: 'Paired devices',
          subtitle: 'Revoke access for a phone or browser',
          onTap: () => context.push('/settings/devices'),
        ),
        SettingsRow.navigation(
          icon: Icons.lan_outlined,
          title: 'Connection details',
          subtitle: connection.label,
          subtitleDotColor: connectionToneColor(connection.tone),
          onTap: () => context.push('/settings/diagnostics'),
        ),
        if (PlatformUpdater.supportedOnCurrentPlatform)
          SettingsRow.action(
            key: const Key('check-for-updates-row'),
            icon: Icons.refresh,
            title: 'Check for updates',
            subtitle: updateCheckSubtitle(
              isMacOS: PlatformFeatures.isMacOS,
              availableVersion: updateState.availableUpdate?.version,
            ),
            trailing: updateState.isChecking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onTap: updateState.isChecking ? null : () => _check(ref),
          ),
      ],
    );
  }

  void _check(WidgetRef ref) {
    // On macOS, Sparkle manages its own UI, so trigger it directly.
    if (PlatformFeatures.isMacOS) {
      MacOSUpdater.checkForUpdates();
      return;
    }
    ref.read(updateProvider.notifier).checkForUpdate();
  }
}

/// Subtitle for the check-for-updates row.
///
/// macOS needs its own string. `UpdateNotifier._initAndCheck` returns early
/// there because Sparkle owns update checking, so `availableUpdate` stays null
/// and the generic wording would claim a clean bill of health from a check that
/// never ran. The old `_CheckForUpdatesTile` said "Opens Sparkle update dialog"
/// for exactly this reason.
///
/// Pure, and takes the platform as an argument, so every branch is reachable
/// from a test host that is none of these platforms.
@visibleForTesting
String updateCheckSubtitle({
  required bool isMacOS,
  required String? availableVersion,
}) {
  if (isMacOS) return 'Opens the Sparkle update dialog';
  if (availableVersion != null) return 'v$availableVersion available';
  return "You're up to date";
}

/// Sign out, kept away from the read-only facts above it.
///
/// `SettingsRow.action` already tints a danger row's title and icon tile with
/// the scheme's error colour, so this needs no styling of its own. The
/// `settings-sign-out` key moves here from the hero's outlined button.
class _AccountSection extends StatelessWidget {
  const _AccountSection({required this.onSignOut});

  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return SettingsSection(
      label: 'Account',
      children: [
        SettingsRow.action(
          key: const Key('settings-sign-out'),
          icon: Icons.logout,
          title: 'Sign out',
          subtitle: 'Signs out of this server on this device',
          danger: true,
          onTap: onSignOut,
        ),
      ],
    );
  }
}

/// The running version, stated once, quietly, at the bottom.
///
/// An empty version renders nothing at all. The hero showed an en dash here,
/// but a footer stating an unknown version is worth less than no footer.
class _VersionFooter extends StatelessWidget {
  const _VersionFooter({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    if (version.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 22, 0, 4),
      child: Text(
        'Mydia Player $version',
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 11.5,
          color: AppColors.textDisabled,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
