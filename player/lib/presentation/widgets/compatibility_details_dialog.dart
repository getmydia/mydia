import 'package:flutter/material.dart';

import '../../core/compatibility/compatibility_provider.dart';
import '../../core/theme/colors.dart';

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
    final requiredVersion = state.requiredVersion;

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.system_update, color: AppColors.warning),
          SizedBox(width: 12),
          Text('Version mismatch'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _explanation,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.border, width: 1),
            ),
            child: Column(
              children: [
                _VersionRow(label: 'Player', value: state.playerVersion),
                _VersionRow(
                  label: 'Server',
                  value: state.serverVersion ?? 'Unknown',
                ),
                if (requiredVersion != null)
                  _VersionRow(
                    label: 'Required',
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
          child: const Text('Close'),
        ),
      ],
    );
  }

  String get _explanation {
    if (state.verdict.isPlayerBehind) {
      return 'This app is older than the connected server expects. '
          'Updating the app should resolve it.';
    }
    return 'This server is older than this app expects. '
        'Whoever runs the server will need to update it.';
  }
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
            style: theme?.copyWith(color: AppColors.textSecondary),
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
