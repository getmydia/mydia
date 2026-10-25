import 'package:flutter/material.dart';

import '../../core/compatibility/compatibility_provider.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/palette.dart';
import '../../l10n/l10n.dart';
import 'glass/glass_dialog.dart';

/// Explains a version mismatch between this player and the connected server.
///
/// Reached from the compatibility banner's "Details" action. Shows both
/// versions and the floor that was not met, so an operator can see at a glance
/// which side is behind and by how much.
class CompatibilityDetailsDialog extends StatelessWidget {
  final CompatibilityState state;

  const CompatibilityDetailsDialog({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final requiredVersion = state.requiredVersion;

    return GlassDialog(
      title: Row(
        children: [
          const Icon(Icons.system_update, color: AppColors.warning),
          const SizedBox(width: 12),
          Text(context.l10n.compatDetailsTitle),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _explanation(context.l10n),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.surfaceVariant,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.border, width: 1),
            ),
            child: Column(
              children: [
                _VersionRow(
                  label: context.l10n.compatDetailsPlayer,
                  value: state.playerVersion,
                ),
                _VersionRow(
                  label: context.l10n.commonServer,
                  value: state.serverVersion ?? context.l10n.commonUnknown,
                ),
                if (requiredVersion != null)
                  _VersionRow(
                    label: context.l10n.compatDetailsRequired,
                    value: requiredVersion,
                    emphasize: true,
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.l10n.commonClose),
        ),
      ],
    );
  }

  String _explanation(AppLocalizations l10n) => state.verdict.isPlayerBehind
      ? l10n.compatDetailsPlayerBehind
      : l10n.compatDetailsServerBehind;
}

/// One labelled version in the comparison table.
class _VersionRow extends StatelessWidget {
  final String label;
  final String value;
  final bool emphasize;

  const _VersionRow({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).textTheme.bodySmall;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme?.copyWith(color: context.palette.textSecondary),
          ),
          Text(
            value,
            style: theme?.copyWith(
              fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
              color: emphasize ? AppColors.warning : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows the details dialog and returns when the user closes it.
Future<void> showCompatibilityDetailsDialog(
  BuildContext context,
  CompatibilityState state,
) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) => CompatibilityDetailsDialog(state: state),
  );
}
