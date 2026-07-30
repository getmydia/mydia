import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';

/// Header for one grouped search section: its title, its honest total, and an
/// optional "Show all" affordance that deep-links to the section on its own.
class SearchSectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final VoidCallback? onShowAll;

  const SearchSectionHeader({
    super.key,
    required this.title,
    required this.count,
    this.onShowAll,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Row(
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '$count',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          const Spacer(),
          if (onShowAll != null)
            TextButton(
              onPressed: onShowAll,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Show all'),
                  SizedBox(width: 2),
                  Icon(Icons.chevron_right_rounded, size: 18),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
