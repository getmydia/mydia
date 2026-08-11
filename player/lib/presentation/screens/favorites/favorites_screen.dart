import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/graphql/watch/query_key.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/colors.dart';
import '../../widgets/browse_grid.dart';
import '../../widgets/browse_scaffold.dart';
import '../../widgets/media_poster.dart';
import 'favorites_controller.dart';

class FavoritesScreen extends ConsumerWidget {
  const FavoritesScreen({super.key});

  void _handleItemTap(BuildContext context, String id, String type) {
    final normalizedType = type.toLowerCase();
    if (normalizedType == 'movie') {
      context.push('/movie/$id');
    } else if (normalizedType == 'tv_show' || normalizedType == 'show') {
      context.push('/show/$id');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favoritesData = ref.watch(favoritesControllerProvider);

    return BrowseScaffold(
      icon: Icons.favorite_rounded,
      title: 'Favorites',
      queryKeys: [QueryKeys.favorites],
      actions: [
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
            onPressed: () => context.push('/search'),
            tooltip: 'Search',
          ),
      ],
      onRefresh: () async {
        await ref.read(favoritesControllerProvider.notifier).refresh();
      },
      body: (context, scrollTopPadding) => favoritesData.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _buildErrorView(context, error, ref),
        data: (items) {
          if (items.isEmpty) return _buildEmptyState(context);
          return BrowseGrid(
            itemCount: items.length,
            scrollTopPadding: scrollTopPadding,
            itemBuilder: (context, index) {
              final item = items[index];
              return MediaPoster(
                key: ValueKey(item.id),
                posterUrl: item.posterUrl,
                title: item.title,
                onTap: () => _handleItemTap(context, item.id, item.type),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildErrorView(BuildContext context, Object error, WidgetRef ref) {
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
              'Failed to load favorites',
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
                ref.read(favoritesControllerProvider.notifier).refresh();
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

  Widget _buildEmptyState(BuildContext context) {
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
              child: const Icon(
                Icons.favorite_outline_rounded,
                size: 56,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No favorites yet',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Mark movies and shows as favorites to see them here',
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
}
