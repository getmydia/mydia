import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/compatibility/compatibility_provider.dart';
import '../../core/compatibility/compatibility_verdict.dart';
import '../../core/theme/colors.dart';
import '../../core/update/install_environment.dart';
import '../../core/update/update_provider.dart';
import '../../l10n/l10n.dart';
import '../screens/settings/dialog/open_settings.dart';
import '../screens/settings/dialog/settings_dialog.dart';
import 'banner_button.dart';
import 'compatibility_details_dialog.dart';
import 'update_action.dart';

/// Warns that this player and the connected server are on incompatible
/// versions.
///
/// Renders nothing unless there is something actionable to say, so it can sit
/// unconditionally in the shell next to [OfflineBanner].
///
/// The update action calls [startUpdate], the one implementation of beginning
/// an update, and falls back to Settings only when there is no update in hand.
/// This used to navigate unconditionally, to avoid a second place that could
/// get the GitHub-versus-app-store question wrong; a shared action answers
/// that instead of working around it.
class CompatibilityBanner extends ConsumerWidget {
  /// Overrides the detected install environment, forwarded to [startUpdate].
  /// Tests only.
  final InstallEnvironment? environmentOverride;

  const CompatibilityBanner({super.key, this.environmentOverride});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `.value` and not `.valueOrNull`: riverpod 3.2.1 has no valueOrNull, and
    // `.value` returns null on AsyncError rather than rethrowing, which is what
    // keeps a failed lookup from throwing into the widget tree.
    final state = ref.watch(compatibilityProvider).value;
    if (state == null || !state.showBanner) return const SizedBox.shrink();

    final color = state.verdict.isRequired ? AppColors.warning : AppColors.info;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        border: Border(
          bottom: BorderSide(color: color.withValues(alpha: 0.3), width: 1),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            Icon(Icons.system_update, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _message(context.l10n, state),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 12),
            BannerButton(
              label: context.l10n.commonDetails,
              color: color,
              onPressed: () => showCompatibilityDetailsDialog(context, state),
            ),
            if (state.verdict.isPlayerBehind) ...[
              const SizedBox(width: 8),
              BannerButton(
                label: context.l10n.commonUpdate,
                color: color,
                onPressed: () {
                  // Settings is the fallback, not the destination. It covers
                  // macOS, where Sparkle owns checking and availableUpdate
                  // stays null, and the window before the first check lands.
                  if (ref.read(updateProvider).availableUpdate == null) {
                    openSettings(context, initial: SettingsCategory.about);
                    return;
                  }
                  startUpdate(
                    context,
                    ref,
                    environmentOverride: environmentOverride,
                  );
                },
              ),
            ],
            if (state.verdict.isDismissible) ...[
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                color: color,
                visualDensity: VisualDensity.compact,
                tooltip: context.l10n.commonDismiss,
                onPressed: () =>
                    ref.read(compatibilityProvider.notifier).dismiss(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _message(AppLocalizations l10n, CompatibilityState state) {
    final floor = state.requiredVersion;

    switch (state.verdict) {
      case CompatibilityVerdict.playerUpdateRequired:
        return floor == null
            ? l10n.compatPlayerUpdateRequiredNoVersion
            : l10n.compatPlayerUpdateRequired(floor);
      case CompatibilityVerdict.serverUpdateRequired:
        return floor == null
            ? l10n.compatServerUpdateRequiredNoVersion
            : l10n.compatServerUpdateRequired(floor);
      case CompatibilityVerdict.playerUpdateRecommended:
        return l10n.compatPlayerUpdateRecommended;
      case CompatibilityVerdict.serverUpdateRecommended:
        return l10n.compatServerUpdateRecommended;
      case CompatibilityVerdict.compatible:
      case CompatibilityVerdict.unknown:
        return '';
    }
  }
}
