import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/compatibility/compatibility_provider.dart';
import '../../core/compatibility/compatibility_verdict.dart';
import '../../core/theme/colors.dart';
import '../../core/update/install_environment.dart';
import '../../core/update/update_provider.dart';
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
                _message(state),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: color,
                ),
              ),
            ),
            const SizedBox(width: 12),
            BannerButton(
              label: 'Details',
              color: color,
              onPressed: () => showCompatibilityDetailsDialog(context, state),
            ),
            if (state.verdict.isPlayerBehind) ...[
              const SizedBox(width: 8),
              BannerButton(
                label: 'Update',
                color: color,
                onPressed: () {
                  // Settings is the fallback, not the destination. It covers
                  // macOS, where Sparkle owns checking and availableUpdate
                  // stays null, and the window before the first check lands.
                  if (ref.read(updateProvider).availableUpdate == null) {
                    context.go('/settings');
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
                tooltip: 'Dismiss',
                onPressed: () =>
                    ref.read(compatibilityProvider.notifier).dismiss(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _message(CompatibilityState state) {
    final floor = state.requiredVersion ?? 'a newer version';

    switch (state.verdict) {
      case CompatibilityVerdict.playerUpdateRequired:
        return 'Update Mydia Player. This server needs version $floor or newer.';
      case CompatibilityVerdict.serverUpdateRequired:
        return 'This server is out of date. Mydia Player needs server version '
            '$floor or newer.';
      case CompatibilityVerdict.playerUpdateRecommended:
        return 'A newer Mydia Player is available for this server.';
      case CompatibilityVerdict.serverUpdateRecommended:
        return 'A newer Mydia server is available for this app.';
      case CompatibilityVerdict.compatible:
      case CompatibilityVerdict.unknown:
        return '';
    }
  }
}
