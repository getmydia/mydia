import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/sources/capabilities.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/theme/colors.dart';
import '../filter/filter_editor_sheet.dart';
import '../sources/source_library_screen.dart';

/// A saved filter, run on the source it is opened under. The filter lives on
/// the device; the source turns it into a library and a query.
class FilterScreen extends ConsumerWidget {
  const FilterScreen({
    super.key,
    required this.sourceId,
    required this.filterId,
  });

  final SourceId sourceId;
  final String filterId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final layoutAsync = ref.watch(sidebarLayoutProvider);

    return layoutAsync.when(
      loading: () => const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(child: Text(error.toString())),
      ),
      data: (layout) {
        final destination = layout.filters[filterId];
        final saved =
            ref.watch(mediaSourceProvider(sourceId))?.as<SavedFilters>();
        final query =
            destination == null ? null : saved?.filterQuery(destination.filter);
        if (destination == null || query == null) {
          return const Scaffold(
            backgroundColor: Colors.transparent,
            body: _FilterNotFoundBody(),
          );
        }
        return SourceLibraryScreen(
          // One screen per filter, so switching filters never reuses the
          // previous one's seeded query.
          key: ValueKey('filter-$filterId'),
          library: query.library,
          initialQuery: query.query,
          title: destination.label,
          icon: Icons.filter_alt_rounded,
          canSaveAsFilter: false,
          actions: [
            PopupMenuButton<String>(
              icon: const Icon(
                Icons.more_vert_rounded,
                color: AppColors.textSecondary,
                size: 22,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              color: AppColors.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              onSelected: (value) {
                if (value == 'save_filter') {
                  showFilterEditor(
                    context: context,
                    ref: ref,
                    initialFilter: destination.filter,
                  );
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'save_filter',
                  child: Text('Save this view as a filter'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _FilterNotFoundBody extends StatelessWidget {
  const _FilterNotFoundBody();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'This filter no longer exists.',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.go('/'),
              child: const Text('Go home'),
            ),
          ],
        ),
      ),
    );
  }
}
