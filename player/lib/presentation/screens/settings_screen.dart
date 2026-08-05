import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/connection/connection_provider.dart';
import '../../core/graphql/graphql_provider.dart';
import '../../core/update/platform_updater.dart';
import '../../core/update/update_provider.dart';
import '../../core/update/updaters/macos_updater.dart';
import '../../domain/models/quality_rung.dart';
import '../widgets/ambient_backdrop_provider.dart';
import '../widgets/cast_actions.dart';
import '../widgets/cast_button.dart';
import '../widgets/connection_status_indicator.dart';
import '../widgets/hls_quality_selector.dart';
import '../widgets/update_tile.dart';
import 'settings/settings_controller.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _handleLogout(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirmed == true && context.mounted) {
      // Clear settings and connection state BEFORE changing auth state,
      // since auth state change triggers router redirect which unmounts this widget.
      final settingsService = ref.read(settingsServiceProvider);
      await settingsService.clearSettings();
      await ref.read(connectionProvider.notifier).clear();

      // Logout last - this sets auth state to unauthenticated which triggers
      // the router redirect to /login. No explicit context.go() needed.
      await ref.read(authStateProvider.notifier).logout();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsControllerProvider);

    // Settings shows the calm static backdrop, never a stale title image
    // (plan U5 / AE3).
    publishBackdropSource(ref, BackdropSource.none);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: const Text('Settings'),
        // SettingsScreen's app bar is always visible (no desktop
        // suppression), so it carries its own cast affordance instead of
        // the shell's overlay — see AppShell._hasOwnCastButton.
        actions: [
          CastButton(onPressed: () => pickCastDevice(context, ref)),
          const SizedBox(width: 8),
        ],
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 64,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  'Failed to load settings',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  error.toString(),
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
        data: (settings) => ListView(
          children: [
            // Account section
            const _SectionHeader(title: 'Account'),
            ListTile(
              leading: const Icon(Icons.person),
              title: Text(settings.username),
              subtitle: Text(settings.serverUrl),
            ),
            ListTile(
              leading: const Icon(Icons.devices),
              title: const Text('Devices'),
              subtitle: const Text('Manage paired devices'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/devices'),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Logout'),
              onTap: () => _handleLogout(context, ref),
            ),
            const Divider(),

            // Playback section
            const _SectionHeader(title: 'Playback'),
            ListTile(
              key: const Key('default-quality-tile'),
              leading: const Icon(Icons.hd),
              title: const Text('Default quality'),
              subtitle: Text(
                QualityRung.fromStorageKey(settings.defaultQuality)?.label ??
                    QualityRung.original.label,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                // The full ladder, not a per-file one: this is a standing
                // preference set outside playback, where there is no source
                // to derive against. Playback narrows it per file and falls
                // back to Original if the stored rung would upscale.
                final current =
                    QualityRung.fromStorageKey(settings.defaultQuality) ??
                        QualityRung.original;
                final picked = await showQualityPicker(
                  context,
                  deriveQualityLadder(sourceHeight: 2160),
                  current,
                );
                if (picked != null && context.mounted) {
                  await ref
                      .read(settingsControllerProvider.notifier)
                      .setDefaultQuality(picked.storageKey);
                }
              },
            ),
            SwitchListTile(
              key: const Key('auto-skip-segments-switch'),
              secondary: const Icon(Icons.fast_forward),
              title: const Text('Automatically skip intros and credits'),
              subtitle: const Text('When off, a skip button appears instead.'),
              value: settings.autoSkipSegments,
              onChanged: (value) => ref
                  .read(settingsControllerProvider.notifier)
                  .setAutoSkipSegments(value),
            ),
            const Divider(),

            // Connection section
            const _SectionHeader(title: 'Connection'),
            const ConnectionStatusTile(),
            const Divider(),

            // Updates section (desktop only — mobile updates through the app
            // stores and web is served by the Mydia server)
            if (PlatformUpdater.supportedOnCurrentPlatform) ...[
              const _SectionHeader(title: 'Updates'),
              // On macOS, Sparkle manages update notifications natively
              if (!Platform.isMacOS) const UpdateTile(),
              const _CheckForUpdatesTile(),
              const Divider(),
            ],
          ],
        ),
      ),
    );
  }
}

/// Manual "Check for Updates" tile.
class _CheckForUpdatesTile extends ConsumerWidget {
  const _CheckForUpdatesTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // On macOS, Sparkle manages its own UI — just trigger it directly
    if (!kIsWeb && Platform.isMacOS) {
      return ListTile(
        leading: const Icon(Icons.refresh),
        title: const Text('Check for Updates'),
        subtitle: const Text('Opens Sparkle update dialog'),
        onTap: () => MacOSUpdater.checkForUpdates(),
      );
    }

    final updateState = ref.watch(updateProvider);

    return ListTile(
      leading: updateState.isChecking
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
      title: const Text('Check for Updates'),
      subtitle: updateState.availableUpdate != null
          ? Text('v${updateState.availableUpdate!.version} available')
          : const Text('You\'re up to date'),
      onTap: updateState.isChecking
          ? null
          : () => ref.read(updateProvider.notifier).checkForUpdate(),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }
}
