/// The browse screen every poster listing of a source shares: Favorites,
/// Unwatched, Recently Added and Continue Watching. Each wraps this with its
/// provider, its words and, for the paged ones, its `loadMore`.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/cache/invalidation_target.dart';
import '../../../core/cache/query_key.dart';
import '../../../core/cache/watcher_registry.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/sources/source.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/sources/item.dart';
import '../../widgets/browse_grid.dart';
import '../../widgets/browse_scaffold.dart';
import '../../widgets/source_artwork.dart';
import '../detail/detail_links.dart';

typedef ListingPosterBuilder = Widget Function(
  BuildContext context,
  ItemSummary item,
  VoidCallback open,
);

/// A search shortcut for the title bar on a layout without the sidebar.
List<Widget> sourceSearchActions(BuildContext context, SourceId sourceId) => [
      if (!Breakpoints.isDesktop(context))
        IconButton(
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.search_rounded, size: 20),
          ),
          onPressed: () => context.push(sourceSearchLocation(sourceId)),
          tooltip: 'Search',
        ),
    ];

class SourceListingScreen extends ConsumerWidget {
  const SourceListingScreen({
    super.key,
    required this.sourceId,
    required this.icon,
    required this.title,
    required this.queryKey,
    required this.items,
    required this.onRetry,
    required this.errorTitle,
    required this.emptyTitle,
    this.emptyIcon,
    this.emptySubtitle,
    this.onLoadMore,
    this.posterFor,
  });

  final SourceId sourceId;
  final IconData icon;
  final String title;

  /// The `SourceKeys.*` key the freshness header and pull-to-refresh read.
  final QueryKey queryKey;
  final AsyncValue<List<ItemSummary>> items;

  /// Restarts a failed load.
  final VoidCallback onRetry;

  /// `Failed to load ...`
  final String errorTitle;
  final String emptyTitle;

  /// Null draws the empty title alone.
  final IconData? emptyIcon;
  final String? emptySubtitle;

  /// Set by a paged listing; called as the grid nears its end.
  final VoidCallback? onLoadMore;

  /// Builds a poster other than the plain one that opens the item.
  final ListingPosterBuilder? posterFor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return BrowseScaffold(
      icon: icon,
      title: title,
      queryKeys: [queryKey],
      actions: sourceSearchActions(context, sourceId),
      onRefresh: () =>
          ref.read(invalidatorProvider).invalidate([queryKey.target]),
      body: (context, scrollTopPadding) => items.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorView(
          title: errorTitle,
          error: error,
          onRetry: onRetry,
        ),
        data: (list) {
          if (list.isEmpty) {
            return _EmptyState(
              icon: emptyIcon,
              title: emptyTitle,
              subtitle: emptySubtitle,
            );
          }
          return NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.metrics.extentAfter < 800) onLoadMore?.call();
              return false;
            },
            child: BrowseGrid(
              itemCount: list.length,
              scrollTopPadding: scrollTopPadding,
              itemBuilder: (context, index) {
                final item = list[index];
                void open() =>
                    context.push(detailLocation(SourceTarget(item.ref)));
                return posterFor?.call(context, item, open) ??
                    SourcePoster(
                      key: ValueKey('source-poster-${item.ref.externalId}'),
                      item: item,
                      onTap: open,
                    );
              },
            ),
          );
        },
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.title,
    required this.error,
    required this.onRetry,
  });

  final String title;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: AppColors.error,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              key: const Key('source-listing-retry'),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try Again'),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, this.icon, this.subtitle});

  final String title;
  final IconData? icon;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final icon = this.icon;
    final subtitle = this.subtitle;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 56, color: AppColors.primary),
              ),
              const SizedBox(height: 24),
            ],
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppColors.textSecondary,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
