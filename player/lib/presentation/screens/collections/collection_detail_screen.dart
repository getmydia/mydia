import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'collection_detail_controller.dart';
import 'collections_controller.dart';
import '../../widgets/freshness_header.dart';
import '../../widgets/media_poster.dart';
import '../../widgets/quality_download_dialog.dart';
import '../../widgets/toast/toaster.dart';
import '../../../core/downloads/collection_sync_providers.dart';
import '../../../core/downloads/collection_sync_service.dart';
import '../../../core/downloads/download_service.dart' show isDownloadSupported;
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/layout/dock_insets.dart';
import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/models/recently_added_item.dart';
import '../../widgets/window_chrome/window_title_row.dart';

class CollectionDetailScreen extends ConsumerWidget {
  final String id;

  const CollectionDetailScreen({super.key, required this.id});

  void _handleItemTap(BuildContext context, String itemId, String type) {
    final normalizedType = type.toLowerCase();
    if (normalizedType == 'movie') {
      context.push('/movie/$itemId');
    } else if (normalizedType == 'tv_show' || normalizedType == 'show') {
      context.push('/show/$itemId');
    }
  }

  /// Builds Collection detail's title-bar header.
  ///
  /// A static, `@visibleForTesting` seam rather than inlined in [build]:
  /// `build` also watches `collectionDetailControllerProvider(id)`, a
  /// GraphQL-backed stream, expensive to satisfy in a widget test that only
  /// wants to check where the cast button lands. This is the exact widget
  /// [build] puts in `Scaffold.appBar`, taking [itemsData] already resolved
  /// rather than watching the provider itself.
  @visibleForTesting
  static PreferredSizeWidget header(
    BuildContext context, {
    required String id,
    required AsyncValue<List<RecentlyAddedItem>> itemsData,
  }) {
    return WindowTitleBar(
      height: WindowTitleRow.heightOf(context),
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded),
        onPressed: () {
          if (context.canPop()) {
            context.pop();
          } else {
            context.go('/collections');
          }
        },
      ),
      title: const Text(
        'Collection',
        style: TextStyle(
          fontWeight: FontWeight.bold,
          letterSpacing: -0.5,
        ),
      ),
      actions: [
        if (isDownloadSupported)
          itemsData.whenOrNull(
                data: (items) => items.isNotEmpty
                    ? _CollectionDownloadButton(
                        collectionId: id,
                        items: items,
                      )
                    : null,
              ) ??
              const SizedBox.shrink(),
      ],
      // The blur and translucent fill this screen always had, kept exactly:
      // only the leading/title/actions now flow through the shared row
      // instead of a plain `AppBar`. The cast button is new here --
      // `WindowTitleRow` always appends one, and this screen never had one
      // before.
      decorate: (row) => ClipRRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: ColoredBox(
            color: AppColors.background.withValues(alpha: 0.8),
            child: row,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemsData = ref.watch(collectionDetailControllerProvider(id));

    // This is a full-window route (pushed outside the shell), and so the sole
    // owner of the title-bar band here: the body has to sit under
    // `removeBand`, or the ambient `MediaQuery.padding.top` still carries the
    // band on top of the app bar's own reserved height.
    return WindowChromeInsets.removeBand(
      child: Builder(
        builder: (context) {
          final barHeight = WindowTitleRow.heightOf(context);
          return Scaffold(
            extendBodyBehindAppBar: true,
            appBar: header(context, id: id, itemsData: itemsData),
            body: Column(
              children: [
                FreshnessHeader(
                  queryKeys: [QueryKeys.collectionItems(id)],
                  topInset: freshnessTopInset(context, appBarHeight: barHeight),
                ),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: () async {
                      await ref
                          .read(collectionDetailControllerProvider(id).notifier)
                          .refresh();
                    },
                    child: itemsData.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
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
              'Failed to load collection',
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
                    .read(collectionDetailControllerProvider(id).notifier)
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
                Icons.collections_bookmark_outlined,
                size: 56,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Collection is empty',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Add items to this collection in Mydia',
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
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final cardSpacing = Breakpoints.getCardSpacing(context);
    final bottomPadding = DockInsets.bottomOf(context);

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
              watchStatus: item.watchStatus,
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

/// Download button for a collection that toggles between download and sync states.
class _CollectionDownloadButton extends ConsumerStatefulWidget {
  final String collectionId;
  final List<RecentlyAddedItem> items;

  const _CollectionDownloadButton({
    required this.collectionId,
    required this.items,
  });

  @override
  ConsumerState<_CollectionDownloadButton> createState() =>
      _CollectionDownloadButtonState();
}

class _CollectionDownloadButtonState
    extends ConsumerState<_CollectionDownloadButton> {
  bool _isSyncing = false;

  /// Look up the collection name from the cached collections list.
  String _getCollectionName() {
    final collectionsAsync = ref.read(collectionsControllerProvider);
    if (collectionsAsync.hasValue) {
      for (final c in collectionsAsync.value!) {
        if (c.id == widget.collectionId) return c.name;
      }
    }
    return 'Collection';
  }

  /// Find a content ID suitable for the quality dialog.
  /// Prefers the first movie, falls back to the collection's first item.
  String _getProbeContentId() {
    final movies = widget.items.where((i) => i.isMovie);
    if (movies.isNotEmpty) return movies.first.id;
    return widget.items.first.id;
  }

  String _getProbeContentType() {
    final movies = widget.items.where((i) => i.isMovie);
    if (movies.isNotEmpty) return 'movie';
    return 'episode';
  }

  Future<void> _startSync(String resolution) async {
    if (_isSyncing) return;
    setState(() => _isSyncing = true);

    try {
      final result = await syncCollectionItems(
        items: widget.items,
        resolution: resolution,
        ref: ref,
      );

      // Save sync config
      final save = ref.read(saveCollectionSyncProvider);
      await save(
        collectionId: widget.collectionId,
        name: _getCollectionName(),
        resolution: resolution,
      );

      if (!mounted) return;

      final message = _buildResultMessage(result);
      showToast(
        context,
        message,
        icon: result.hasNewDownloads ? Icons.download_rounded : null,
      );
    } catch (e) {
      debugPrint('Collection sync failed: $e');
      if (!mounted) return;
      showToast(context, 'Sync failed: $e', kind: ToastKind.error);
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  String _buildResultMessage(CollectionSyncResult result) {
    if (result.totalQueued == 0 && result.skipped > 0) {
      return 'All ${result.skipped} items already downloaded or queued';
    }
    final parts = <String>[];
    if (result.moviesQueued > 0) {
      parts.add(
          '${result.moviesQueued} movie${result.moviesQueued != 1 ? 's' : ''}');
    }
    if (result.episodesQueued > 0) {
      parts.add(
          '${result.episodesQueued} episode${result.episodesQueued != 1 ? 's' : ''}');
    }
    final queuedStr = parts.join(' and ');
    final msg = 'Queued $queuedStr for download';
    if (result.skipped > 0) {
      return '$msg, ${result.skipped} already downloaded';
    }
    return msg;
  }

  Future<void> _handleDownloadTap() async {
    final selectedResolution = await showQualityDownloadDialog(
      context,
      contentType: _getProbeContentType(),
      contentId: _getProbeContentId(),
      title: _getCollectionName(),
    );

    if (selectedResolution == null || !mounted) return;
    await _startSync(selectedResolution);
  }

  Future<void> _handleSyncNow() async {
    final config = await ref.read(
      collectionSyncConfigProvider(widget.collectionId).future,
    );
    if (config == null || !mounted) return;
    await _startSync(config['resolution']!);
  }

  Future<void> _handleStopSyncing() async {
    final remove = ref.read(removeCollectionSyncProvider);
    await remove(widget.collectionId);
  }

  @override
  Widget build(BuildContext context) {
    final isSyncedAsync =
        ref.watch(isCollectionSyncedProvider(widget.collectionId));

    if (_isSyncing) {
      return const Padding(
        padding: EdgeInsets.only(right: 12),
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    final isSynced = isSyncedAsync.maybeWhen(
      data: (value) => value,
      orElse: () => false,
    );

    if (isSynced) {
      return PopupMenuButton<String>(
        icon: const Icon(
          Icons.sync_rounded,
          color: AppColors.primary,
          size: 22,
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        style: const ButtonStyle(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        onSelected: (value) {
          if (value == 'sync_now') {
            _handleSyncNow();
          } else if (value == 'stop') {
            _handleStopSyncing();
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'sync_now',
            child: Row(
              children: [
                Icon(Icons.sync_rounded, size: 18),
                SizedBox(width: 12),
                Text('Sync Now'),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'stop',
            child: Row(
              children: [
                Icon(Icons.sync_disabled_rounded, size: 18),
                SizedBox(width: 12),
                Text('Stop Syncing'),
              ],
            ),
          ),
        ],
      );
    }

    return IconButton(
      icon: const Icon(
        Icons.download_rounded,
        color: AppColors.textSecondary,
        size: 22,
      ),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      style: const ButtonStyle(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      onPressed: _handleDownloadTap,
    );
  }
}
