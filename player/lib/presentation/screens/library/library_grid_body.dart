import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/graphql/watch/query_key.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/navigation/media_filter.dart';
import '../../models/library_data.dart';
import '../../widgets/freshness_header.dart';
import '../../widgets/media_poster.dart';
import 'library_controller.dart';

enum LibraryViewMode { grid, list }

QueryKey freshnessKeyForFilter(MediaFilter filter) {
  if (filter.watch == WatchScope.unwatched) {
    return QueryKeys.unwatchedList;
  }
  if (filter.watch == WatchScope.favorites) {
    return QueryKeys.favoritesList;
  }
  return filter.kind == MediaKind.movies
      ? QueryKeys.moviesList
      : QueryKeys.tvShowsList;
}

class LibraryMediaBody extends ConsumerStatefulWidget {
  final MediaFilter filter;
  final ScrollController scrollController;
  final double chromeTop;
  final double scrollTopPadding;
  final LibraryViewMode viewMode;
  final String emptyTitle;
  final String emptySubtitle;
  final IconData emptyIcon;
  final String searchQuery;
  final VoidCallback? onSearchClear;

  const LibraryMediaBody({
    super.key,
    required this.filter,
    required this.scrollController,
    required this.chromeTop,
    required this.scrollTopPadding,
    required this.viewMode,
    required this.emptyTitle,
    required this.emptySubtitle,
    required this.emptyIcon,
    this.searchQuery = '',
    this.onSearchClear,
  });

  @override
  ConsumerState<LibraryMediaBody> createState() => _LibraryMediaBodyState();
}

class _LibraryMediaBodyState extends ConsumerState<LibraryMediaBody> {
  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (!widget.scrollController.hasClients) return;
    if (widget.scrollController.position.pixels >=
        widget.scrollController.position.maxScrollExtent - 200) {
      ref.read(libraryControllerProvider(widget.filter).notifier).loadMore();
    }
  }

  void _handleItemTap(String id, String type) {
    final normalizedType = type.toLowerCase();
    if (normalizedType == 'movie') {
      context.push('/movie/$id');
    } else if (normalizedType == 'tv_show' || normalizedType == 'show') {
      context.push('/show/$id');
    }
  }

  @override
  Widget build(BuildContext context) {
    final libraryAsync = ref.watch(libraryControllerProvider(widget.filter));

    return Stack(
      children: [
        RefreshIndicator(
          edgeOffset: widget.chromeTop,
          onRefresh: () async {
            await ref
                .read(libraryControllerProvider(widget.filter).notifier)
                .refresh();
          },
          child: libraryAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => _buildErrorView(error),
            data: (data) {
              if (data.isEmpty) {
                return _buildEmptyState();
              }

              final searchQuery = widget.searchQuery.toLowerCase().trim();
              final filteredItems = searchQuery.isEmpty
                  ? data.items
                  : data.items
                      .where(
                        (item) =>
                            item.title.toLowerCase().contains(searchQuery),
                      )
                      .toList();

              if (filteredItems.isEmpty && searchQuery.isNotEmpty) {
                return _buildNoSearchResultsState(searchQuery);
              }

              return widget.viewMode == LibraryViewMode.grid
                  ? _buildGridView(context, filteredItems)
                  : _buildListView(context, filteredItems);
            },
          ),
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: FreshnessHeader(
            queryKeys: [freshnessKeyForFilter(widget.filter)],
            topInset: widget.chromeTop,
          ),
        ),
      ],
    );
  }

  Widget _buildErrorView(Object error) {
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
              'Failed to load library',
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
              onPressed: () {
                ref
                    .read(libraryControllerProvider(widget.filter).notifier)
                    .refresh();
              },
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

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                widget.emptyIcon,
                size: 56,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              widget.emptyTitle,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              widget.emptySubtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoSearchResultsState(String query) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.search_off_rounded,
                size: 56,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No results found',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'No matches for "$query"',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
            if (widget.onSearchClear != null) ...[
              const SizedBox(height: 24),
              TextButton(
                onPressed: widget.onSearchClear,
                child: const Text('Clear search'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildGridView(BuildContext context, List<LibraryItem> items) {
    final isDesktop = Breakpoints.isDesktop(context);
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final cardSpacing = Breakpoints.getCardSpacing(context);
    final bottomPadding = isDesktop ? 32.0 : 100.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        return GridView.builder(
          controller: widget.scrollController,
          padding: EdgeInsets.fromLTRB(horizontalPadding,
              widget.scrollTopPadding, horizontalPadding, bottomPadding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: libraryCrossAxisCount(constraints.maxWidth),
            childAspectRatio: 0.58,
            crossAxisSpacing: cardSpacing,
            mainAxisSpacing: cardSpacing + 4,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return MediaPoster(
              key: ValueKey(item.id),
              posterUrl: item.posterUrl,
              title: item.title,
              progressPercentage: item.progressPercentage,
              rating: item.rating,
              isFavorite: item.isFavorite,
              onTap: () => _handleItemTap(item.id, item.type),
            );
          },
        );
      },
    );
  }

  Widget _buildListView(BuildContext context, List<LibraryItem> items) {
    final isDesktop = Breakpoints.isDesktop(context);
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final bottomPadding = isDesktop ? 32.0 : 100.0;

    return ListView.builder(
      controller: widget.scrollController,
      padding: EdgeInsets.fromLTRB(horizontalPadding, widget.scrollTopPadding,
          horizontalPadding, bottomPadding),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return LibraryListItem(
          item: item,
          onTap: () => _handleItemTap(item.id, item.type),
        );
      },
    );
  }
}

int libraryCrossAxisCount(double width) {
  if (width > 1400) return 8;
  if (width > 1200) return 7;
  if (width > 1000) return 6;
  if (width > 800) return 5;
  if (width > 600) return 4;
  if (width > 400) return 3;
  return 2;
}

class LibraryListItem extends StatelessWidget {
  final LibraryItem item;
  final VoidCallback onTap;

  const LibraryListItem({
    super.key,
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 60,
                    height: 90,
                    child: MediaPoster(
                      posterUrl: item.posterUrl,
                      title: item.title,
                      progressPercentage: item.progressPercentage,
                      isFavorite: item.isFavorite,
                      showTitle: false,
                      onTap: onTap,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (item.subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          item.subtitle!,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                if (item.isFavorite)
                  const Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: Icon(
                      Icons.favorite_rounded,
                      color: AppColors.error,
                      size: 20,
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textSecondary,
                    size: 24,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
