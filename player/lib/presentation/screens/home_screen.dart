import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/cache/poster_cache_manager.dart';
import '../../core/graphql/watch/query_key.dart';
import '../../core/player/best_file.dart';
import '../../core/player/resume_plan.dart';
import '../../domain/models/continue_watching_item.dart';
import '../../domain/models/media_file.dart';
import '../widgets/ambient_backdrop_provider.dart';
import '../widgets/content_rail.dart';
import '../widgets/freshness_header.dart';
import '../widgets/glass_surface.dart';
import '../widgets/shimmer_card.dart';
import '../../core/layout/breakpoints.dart';
import '../../core/layout/dock_insets.dart';
import '../../core/theme/colors.dart';
import '../widgets/app_shell.dart';
import '../widgets/mydia_logo.dart';
import 'home/home_controller.dart';

String _resumeSuffix({
  required bool isContinueState,
  required int? positionSeconds,
  required bool watched,
}) {
  final pass = shouldPassResume(
    isContinueState: isContinueState,
    positionSeconds: positionSeconds,
    watched: watched,
  );
  return pass ? '&resume=$positionSeconds' : '';
}

/// Player route for a Continue Watching card.
///
/// This rail carries movies as well as episodes, and by construction every
/// item on it is mid-playback, so the resume gate only has to check position
/// and watched state.
String playerRouteForContinueWatching(
  ContinueWatchingItem item, {
  required String fileId,
}) {
  final progress = item.progress;
  final resume = _resumeSuffix(
    isContinueState: true,
    positionSeconds: progress?.positionSeconds,
    watched: progress?.watched ?? false,
  );

  if (item.isMovie) {
    return '/player/movie/${item.id}'
        '?fileId=$fileId'
        '&title=${Uri.encodeComponent(item.title)}'
        '$resume';
  }

  final showId = item.showId;
  final seasonNumber = item.seasonNumber;

  return '/player/episode/${item.id}'
      '?fileId=$fileId'
      '&title=${Uri.encodeComponent(item.displayTitle)}'
      '${showId != null ? '&showId=$showId' : ''}'
      '${seasonNumber != null ? '&seasonNumber=$seasonNumber' : ''}'
      '$resume';
}

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  void _handleItemTap(BuildContext context, String id, String type) {
    final normalizedType = type.toLowerCase();
    if (normalizedType == 'movie') {
      context.push('/movie/$id');
    } else if (normalizedType == 'tv_show' || normalizedType == 'show') {
      context.push('/show/$id');
    } else if (normalizedType == 'episode') {
      context.push('/episode/$id');
    }
  }

  /// Picks the best file, or null when none is playable and also when the
  /// selection itself fails.
  ///
  /// pickBestFile probes the device and network, so it can throw on a flaky
  /// connection. An escaping error would leave the tap doing nothing at all,
  /// so a failed probe is treated like "nothing playable" and lands the user
  /// on the detail screen, where they can pick a version by hand.
  Future<MediaFile?> _bestFileOrNull(
    List<MediaFile> files,
    double screenWidth,
  ) async {
    try {
      return await pickBestFile(files, screenWidth);
    } catch (error, stackTrace) {
      debugPrint('Best-file selection failed, falling back to detail: $error');
      debugPrintStack(stackTrace: stackTrace);
      return null;
    }
  }

  Future<void> _handlePlay(BuildContext context, Object item) async {
    final router = GoRouter.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;

    if (item is ContinueWatchingItem) {
      final file = await _bestFileOrNull(item.files, screenWidth);
      if (file == null) {
        router.push(item.isMovie ? '/movie/${item.id}' : '/episode/${item.id}');
        return;
      }
      router.push(playerRouteForContinueWatching(item, fileId: file.id));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final homeData = ref.watch(homeControllerProvider);
    final isDesktop = Breakpoints.isDesktop(context);
    // On desktop, no bottom nav so less padding needed
    final bottomPadding = DockInsets.bottomOf(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: isDesktop ? null : _ModernAppBar(),
      body: Column(
        children: [
          FreshnessHeader(
            queryKeys: [QueryKeys.home],
            topInset: freshnessTopInset(
              context,
              appBarHeight: isDesktop ? null : kToolbarHeight,
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await ref.read(homeControllerProvider.notifier).refresh();
              },
              child: homeData.when(
                loading: () {
                  // No hero pick yet -> calm static fallback.
                  publishBackdropSource(ref, BackdropSource.none);
                  return _buildShimmerLoading(context);
                },
                error: (error, stackTrace) {
                  publishBackdropSource(ref, BackdropSource.none);
                  return _buildErrorView(context, error, ref);
                },
                data: (data) {
                  if (data.isEmpty) {
                    publishBackdropSource(ref, BackdropSource.none);
                    return _buildEmptyState(context);
                  }

                  // Feed the shell ambient backdrop from the hero pick:
                  // continueWatching.first ?? recentlyAdded.first, using
                  // backdropUrl ?? posterUrl (plan U5 / AE1). Branch by
                  // concrete type so the getters resolve (the two lists
                  // hold different types).
                  final BackdropSource heroSource;
                  if (data.continueWatching.isNotEmpty) {
                    final item = data.continueWatching.first;
                    heroSource = BackdropSource(
                      imageUrl: item.backdropUrl ?? item.posterUrl,
                      id: item.id,
                    );
                  } else if (data.recentlyAdded.isNotEmpty) {
                    final item = data.recentlyAdded.first;
                    heroSource = BackdropSource(
                      imageUrl: item.backdropUrl ?? item.posterUrl,
                      id: item.id,
                    );
                  } else {
                    heroSource = BackdropSource.none;
                  }
                  publishBackdropSource(ref, heroSource);

                  return CustomScrollView(
                    slivers: [
                      // Hero section with featured content
                      if (data.continueWatching.isNotEmpty ||
                          data.recentlyAdded.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Builder(builder: (context) {
                            if (data.continueWatching.isNotEmpty) {
                              final item = data.continueWatching.first;
                              return _HeroSection(
                                item: item,
                                onTap: () =>
                                    _handleItemTap(context, item.id, item.type),
                              );
                            } else {
                              final item = data.recentlyAdded.first;
                              return _HeroSection(
                                item: item,
                                onTap: () =>
                                    _handleItemTap(context, item.id, item.type),
                              );
                            }
                          }),
                        ),

                      // Content rails
                      SliverList(
                        delegate: SliverChildListDelegate([
                          if (data.continueWatching.isNotEmpty)
                            ContentRail(
                              title: 'Continue Watching',
                              items: data.continueWatching,
                              showProgress: true,
                              onItemTap: (id, type) =>
                                  _handleItemTap(context, id, type),
                              onItemActivate: (item) =>
                                  _handlePlay(context, item),
                            ),
                          if (data.recentlyAdded.isNotEmpty)
                            ContentRail(
                              title: 'Recently Added',
                              items: data.recentlyAdded,
                              onItemTap: (id, type) =>
                                  _handleItemTap(context, id, type),
                              onSeeAllTap: () =>
                                  context.push('/recently-added'),
                            ),
                          if (data.favorites.isNotEmpty)
                            ContentRail(
                              title: 'Favorites',
                              items: data.favorites,
                              onItemTap: (id, type) =>
                                  _handleItemTap(context, id, type),
                              onSeeAllTap: () => context.push('/favorites'),
                            ),
                          SizedBox(height: bottomPadding),
                        ]),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildShimmerLoading(BuildContext context) {
    final isDesktop = Breakpoints.isDesktop(context);
    final safeAreaTop = MediaQuery.of(context).padding.top;
    return ListView(
      padding:
          EdgeInsets.only(top: isDesktop ? 0 : safeAreaTop + kToolbarHeight),
      children: [
        const _ShimmerHero(),
        SizedBox(height: isDesktop ? 32 : 24),
        const ShimmerRail(count: 5),
        SizedBox(height: isDesktop ? 24 : 16),
        const ShimmerRail(count: 5),
        SizedBox(height: isDesktop ? 24 : 16),
        const ShimmerRail(count: 5),
      ],
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
                Icons.wifi_off_rounded,
                size: 48,
                color: AppColors.error,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Unable to connect',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Check your connection and try again',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () {
                ref.read(homeControllerProvider.notifier).refresh();
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
                Icons.movie_filter_rounded,
                size: 56,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Your library awaits',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Add some movies and shows to start streaming',
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

class _ModernAppBar extends StatelessWidget implements PreferredSizeWidget {
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return GlassSurface.appBar(
      child: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        titleSpacing: 0,
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
            MydiaLogo(size: 32),
            SizedBox(width: 10),
            Text(
              'Mydia Player',
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
    );
  }
}

class _HeroSection extends StatelessWidget {
  final dynamic item;
  final VoidCallback onTap;

  const _HeroSection({
    required this.item,
    required this.onTap,
  });

  String? get _backdropUrl {
    if (item.backdropUrl != null) return item.backdropUrl;
    return item.posterUrl;
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = Breakpoints.isDesktop(context);
    // On desktop, cap hero height at 450px; on mobile use 50% of screen
    final heroHeight = isDesktop
        ? (size.height * 0.45).clamp(300.0, 450.0)
        : size.height * 0.5;
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);

    return GestureDetector(
      onTap: onTap,
      child: Stack(
        children: [
          // Static background image (parallax removed in favor of resting
          // depth, plan R11/U9).
          ClipRect(
            child: SizedBox(
              width: size.width,
              height: heroHeight,
              child: _backdropUrl != null
                  ? CachedNetworkImage(
                      imageUrl: _backdropUrl!,
                      fit: BoxFit.cover,
                      cacheManager: BackdropCacheManager(),
                      placeholder: (context, url) => Container(
                        color: AppColors.surface,
                      ),
                      errorWidget: (context, url, error) => Container(
                        color: AppColors.surface,
                        child: const Icon(
                          Icons.movie_rounded,
                          size: 64,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    )
                  : Container(
                      color: AppColors.surface,
                      child: const Icon(
                        Icons.movie_rounded,
                        size: 64,
                        color: AppColors.textSecondary,
                      ),
                    ),
            ),
          ),

          // Gradient overlays
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.background.withValues(alpha: 0.4),
                    Colors.transparent,
                    AppColors.background.withValues(alpha: 0.9),
                    AppColors.background,
                  ],
                  stops: const [0.0, 0.3, 0.7, 1.0],
                ),
              ),
            ),
          ),

          // Content overlay
          Positioned(
            left: horizontalPadding,
            right: horizontalPadding,
            bottom: isDesktop ? 32 : 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Featured badge
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'FEATURED',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Title
                Text(
                  item.title,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    shadows: [
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.5),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),

                // Subtitle/info
                if (item.showTitle != null)
                  Text(
                    item.showTitle!,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppColors.textSecondary,
                        ),
                  ),

                const SizedBox(height: 16),

                // Action buttons
                Row(
                  children: [
                    // Play button
                    FilledButton.icon(
                      onPressed: onTap,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Play'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),

                    // More info button
                    OutlinedButton.icon(
                      onPressed: onTap,
                      icon: const Icon(Icons.info_outline_rounded, size: 20),
                      label: const Text('More Info'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 14,
                        ),
                        side: BorderSide(
                          color: AppColors.textSecondary.withValues(alpha: 0.5),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShimmerHero extends StatelessWidget {
  const _ShimmerHero();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isDesktop = Breakpoints.isDesktop(context);
    // Match the responsive hero height from _HeroSection
    final heroHeight = isDesktop
        ? (size.height * 0.45).clamp(300.0, 450.0)
        : size.height * 0.5;
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);

    return Container(
      width: size.width,
      height: heroHeight,
      color: AppColors.surface,
      child: Stack(
        children: [
          // Shimmer effect
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    AppColors.background.withValues(alpha: 0.4),
                    Colors.transparent,
                    AppColors.background.withValues(alpha: 0.9),
                    AppColors.background,
                  ],
                  stops: const [0.0, 0.3, 0.7, 1.0],
                ),
              ),
            ),
          ),
          Positioned(
            left: horizontalPadding,
            right: horizontalPadding,
            bottom: isDesktop ? 32 : 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 80,
                  height: 20,
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  width: 200,
                  height: 32,
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 120,
                  height: 20,
                  decoration: BoxDecoration(
                    color: AppColors.shimmerBase,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      width: 100,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.shimmerBase,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      width: 120,
                      height: 44,
                      decoration: BoxDecoration(
                        color: AppColors.shimmerBase,
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
