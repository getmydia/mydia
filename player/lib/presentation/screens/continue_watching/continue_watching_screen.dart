import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/graphql/watch/query_key.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/models/continue_watching_item.dart';
import '../../../domain/models/watch_status.dart';
import '../../widgets/browse_grid.dart';
import '../../widgets/browse_scaffold.dart';
import '../../widgets/media_context_menu.dart';
import '../../widgets/media_poster.dart';
import 'continue_watching_actions.dart' as cw_actions;
import 'continue_watching_controller.dart';

class ContinueWatchingScreen extends ConsumerStatefulWidget {
  const ContinueWatchingScreen({super.key});

  @override
  ConsumerState<ContinueWatchingScreen> createState() =>
      _ContinueWatchingScreenState();
}

class _ContinueWatchingScreenState
    extends ConsumerState<ContinueWatchingScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(continueWatchingControllerProvider.notifier).loadMore();
    }
  }

  void _openMenu(BuildContext posterContext, ContinueWatchingItem item) {
    showMediaContextMenu(
      posterContext,
      target: MediaContextTarget(
        id: item.id,
        type: item.type,
        showId: item.showId,
        hasFile: item.files.isNotEmpty,
        continueWatchingId: item.continueWatchingKey,
      ),
      // Unreachable: with `tapPlays` false the menu never offers Play.
      onPlay: () {},
      onRemoveFromContinueWatching: () => _handleRemove(item),
    );
  }

  Future<void> _handleRemove(ContinueWatchingItem item) async {
    final key = item.continueWatchingKey;
    if (key == null) return;

    await cw_actions.reportRemovalFailure(
      context,
      () => ref
          .read(continueWatchingControllerProvider.notifier)
          .removeFromContinueWatching(key),
    );
  }

  void _handleItemTap(BuildContext context, ContinueWatchingItem item) {
    final normalizedType = item.type.toLowerCase();
    if (normalizedType == 'movie') {
      context.push('/movie/${item.id}');
    } else if (normalizedType == 'episode') {
      context.push('/episode/${item.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(continueWatchingControllerProvider);

    return BrowseScaffold(
      icon: Icons.play_circle_outline_rounded,
      title: 'Continue Watching',
      queryKeys: [QueryKeys.continueWatchingList],
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
        await ref.read(continueWatchingControllerProvider.notifier).refresh();
      },
      body: (context, scrollTopPadding) => data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _buildErrorView(context, error, ref),
        data: (page) {
          if (page.isEmpty) return _buildEmptyState(context);
          return BrowseGrid(
            controller: _scrollController,
            itemCount: page.items.length,
            scrollTopPadding: scrollTopPadding,
            itemBuilder: (context, index) {
              final item = page.items[index];
              return MediaPoster(
                key: ValueKey(item.id),
                posterUrl: item.posterUrl,
                title: item.title,
                subtitle: item.showTitle,
                // Continue Watching keeps `ProgressFragment` and adapts it
                // here rather than asking the server for a `watchStatus` it
                // would have to compute for a rail where every item is
                // part-played by definition. Going through `WatchStatus` is
                // what puts this rail on the same rendering rule as every
                // other surface, instead of the legacy percentage prop.
                watchStatus: item.progress == null
                    ? null
                    : WatchStatus.fromProgress(item.progress!),
                onTap: () => _handleItemTap(context, item),
                // `tapPlays` stays false here: this grid opens the title, it
                // does not play it. That suppresses the navigation entries,
                // which would only repeat the tap, and leaves the removal.
                onContextMenu: (posterContext) =>
                    _openMenu(posterContext, item),
                showMenuButton: item.continueWatchingKey != null,
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
              'Failed to load continue watching',
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
                ref.read(continueWatchingControllerProvider.notifier).refresh();
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
        child: Text(
          'Nothing in progress.',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
