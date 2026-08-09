import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import 'library_sort.dart';

/// Bottom sheet for picking a library sort field and direction.
class LibrarySortSheet extends StatelessWidget {
  const LibrarySortSheet({super.key, required this.currentSort});

  final LibrarySort currentSort;

  @override
  Widget build(BuildContext context) {
    final directionEnabled = currentSort.field.supportsDirection;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textSecondary.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                const Icon(Icons.sort_rounded, size: 24),
                const SizedBox(width: 12),
                Text(
                  'Sort by',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const Spacer(),
                TextButton.icon(
                  key: const Key('sort-direction-toggle'),
                  onPressed: directionEnabled
                      ? () => Navigator.of(context).pop(
                            LibrarySortSelection.toggleDirection(),
                          )
                      : null,
                  icon: Icon(
                    currentSort.direction == SortDirection.asc
                        ? Icons.arrow_upward_rounded
                        : Icons.arrow_downward_rounded,
                    size: 18,
                  ),
                  label: Text(
                    currentSort.direction == SortDirection.asc ? 'Asc' : 'Desc',
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ...SortField.values.map((field) {
            final isSelected = field == currentSort.field;
            return ListTile(
              key: Key('sort-field-${field.wireName}'),
              leading: Icon(
                isSelected ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: isSelected ? AppColors.primary : AppColors.textSecondary,
              ),
              title: Text(
                field.displayName,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected ? AppColors.primary : AppColors.textPrimary,
                ),
              ),
              onTap: () =>
                  Navigator.of(context).pop(LibrarySortSelection.field(field)),
            );
          }),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// What a sort sheet returns: either a chosen field, or a direction flip.
class LibrarySortSelection {
  const LibrarySortSelection.field(this.field) : toggleOnly = false;
  const LibrarySortSelection.toggleDirection()
      : field = null,
        toggleOnly = true;

  final SortField? field;
  final bool toggleOnly;
}
