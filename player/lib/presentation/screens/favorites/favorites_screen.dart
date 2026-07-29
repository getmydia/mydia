import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'favorites_controller.dart';
import '../../widgets/media_poster.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/freshness_header.dart';
import '../../widgets/glass_surface.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/colors.dart';

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
    final isDesktop = Breakpoints.isDesktop(context);

    // Grid screens use the calm static backdrop (no per-title artwork).
    publishBackdropSource(ref, BackdropSource.none);

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(context, isDesktop),
      body: Column(
        children: [
          FreshnessHeader(
            queryKeys: [QueryKeys.favorites],
            topInset: freshnessTopInset(
              context,
              appBarHeight: isDesktop ? null : kToolbarHeight,
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await ref.read(favoritesControllerProvider.notifier).refresh();
              },
              child: favoritesData.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => _buildErrorView(context, error, ref),
                data: (items) {
                  if (items.isEmpty) {
                    return _buildEmptyState(context);
                  }
                  return _buildGridView(context, items);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, bool isDesktop) {
    if (isDesktop)
      return const PreferredSize(
          preferredSize: Size.fromHeight(0), child: SizedBox.shrink());
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: GlassSurface.appBar(
        child: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.menu_rounded),
            onPressed: () {
              AppShell.scaffoldKey.currentState?.openDrawer();
            },
            tooltip: 'Menu',
          ),
          title: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.favorite_rounded,
                color: AppColors.primary,
                size: 22,
              ),
              SizedBox(width: 10),
              Text(
                'Favorites',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  letterSpacing: -0.5,
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.surfaceVariant.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.search_rounded, size: 20),
              ),
              onPressed: () {
                context.push('/search');
              },
              tooltip: 'Search',
            ),
            const SizedBox(width: 8),
          ],
        ),
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

  Widget _buildGridView(BuildContext context, List items) {
    final isDesktop = Breakpoints.isDesktop(context);
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final cardSpacing = Breakpoints.getCardSpacing(context);
    final bottomPadding = isDesktop ? 32.0 : 100.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = _calculateCrossAxisCount(constraints.maxWidth);

        return GridView.builder(
          padding: EdgeInsets.fromLTRB(
              horizontalPadding, 100, horizontalPadding, bottomPadding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
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
              onTap: () => _handleItemTap(context, item.id, item.type),
            );
          },
        );
      },
    );
  }

  int _calculateCrossAxisCount(double width) {
    if (width > 1400) return 8;
    if (width > 1200) return 7;
    if (width > 1000) return 6;
    if (width > 800) return 5;
    if (width > 600) return 4;
    if (width > 400) return 3;
    return 2;
  }
}
