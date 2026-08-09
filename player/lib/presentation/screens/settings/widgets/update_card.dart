import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/player/platform_features.dart';
import '../../../../core/theme/colors.dart';
import '../../../../core/update/platform_updater.dart';
import '../../../../core/update/update_provider.dart';
import 'settings_section.dart';

/// The available-update card, shown above the settings sections.
///
/// Gated on three conditions, all of which matter:
///
/// * [PlatformUpdater.supportedOnCurrentPlatform] is `!isWeb && !isAndroid &&
///   !isIOS`. `UpdateNotifier._initAndCheck` only returns early on web and
///   macOS, so an update check *does* run on iOS and Android and
///   `availableUpdate` can be non-null there. Without this check the card would
///   offer an Update Now button on a platform that updates through a store.
/// * Not macOS, where Sparkle owns update notification natively.
/// * An update actually being available.
///
/// The old `UpdateTile` got the first condition from the enclosing `if` in the
/// settings screen. Moving it in here means the screen cannot forget it.
class UpdateCard extends ConsumerWidget {
  /// Overrides the platform-support check. Tests only: a `flutter test` host on
  /// Linux always reports a supported platform, so the unsupported branch is
  /// otherwise unreachable. Mirrors `LocalNetworkSettingsButton.available`.
  final bool? supportedOverride;

  const UpdateCard({super.key, this.supportedOverride});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final supported =
        supportedOverride ?? PlatformUpdater.supportedOnCurrentPlatform;
    if (!supported || PlatformFeatures.isMacOS) return const SizedBox.shrink();

    final updateState = ref.watch(updateProvider);
    final update = updateState.availableUpdate;
    if (update == null) return const SizedBox.shrink();

    return SettingsCard(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Update available: v${update.version}',
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                update.releaseTitle,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              if (updateState.isApplying)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(
                      value: updateState.downloadProgress > 0
                          ? updateState.downloadProgress
                          : null,
                    ),
                    const SizedBox(height: 6),
                    // At zero the bar is indeterminate, so a "0%" label would
                    // claim a precision the bar itself is not showing.
                    Text(
                      updateState.downloadProgress > 0
                          ? 'Downloading ${(updateState.downloadProgress * 100).toInt()}%'
                          : 'Downloading',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: () => _handleUpdateTap(context, ref),
                      icon: const Icon(Icons.download, size: 18),
                      label: const Text('Update Now'),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () =>
                          _openReleaseNotes(update.releaseNotesUrl),
                      child: const Text('Release Notes'),
                    ),
                  ],
                ),
              if (updateState.error != null) ...[
                const SizedBox(height: 8),
                Text(
                  updateState.error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  void _handleUpdateTap(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(updateProvider.notifier);

    if (!notifier.canUpdateInPlace) {
      notifier.applyUpdate();
      return;
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update Mydia'),
        content: Text(
          'Mydia will close and update to '
          'v${ref.read(updateProvider).availableUpdate?.version}. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              notifier.applyUpdate();
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  Future<void> _openReleaseNotes(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}
