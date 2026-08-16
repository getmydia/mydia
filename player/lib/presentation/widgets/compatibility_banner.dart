import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/compatibility/compatibility_provider.dart';
import '../../core/compatibility/compatibility_verdict.dart';
import '../../core/theme/colors.dart';
import 'compatibility_details_dialog.dart';

/// Warns that this player and the connected server are on incompatible
/// versions.
///
/// Renders nothing unless there is something actionable to say, so it can sit
/// unconditionally in the shell next to [OfflineBanner].
///
/// The update action navigates to Settings rather than starting a download.
/// Settings already hosts UpdateCard, which resolves the right update path per
/// platform. Duplicating that here would give us two places to get the
/// GitHub-versus-app-store question wrong.
class CompatibilityBanner extends ConsumerWidget {
  const CompatibilityBanner({super.key});

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
            _BannerButton(
              label: 'Details',
              color: color,
              onPressed: () => showCompatibilityDetailsDialog(context, state),
            ),
            if (state.verdict.isPlayerBehind) ...[
              const SizedBox(width: 8),
              _BannerButton(
                label: 'Update',
                color: color,
                onPressed: () => context.go('/settings'),
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

/// A compact action styled to sit inside the banner, matching OfflineBanner.
class _BannerButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onPressed;

  const _BannerButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: color.withValues(alpha: 0.2),
        foregroundColor: color,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
