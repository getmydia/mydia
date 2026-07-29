import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'library_controller.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/freshness_header.dart';
import '../../widgets/glass_surface.dart';
import '../../widgets/media_poster.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/colors.dart';

enum ViewMode { grid, list }

class LibraryScreen extends ConsumerStatefulWidget {
  final LibraryType libraryType;

  const LibraryScreen({
    super.key,
    required this.libraryType,
  });

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  ViewMode _viewMode = ViewMode.grid;
  SortOption _currentSort = SortOption.recentlyAdded;
  bool _showSearch = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref
          .read(libraryControllerProvider(widget.libraryType).notifier)
          .loadMore();
    }
  }

  void _toggleViewMode() {
    setState(() {
      _viewMode = _viewMode == ViewMode.grid ? ViewMode.list : ViewMode.grid;
    });
  }

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) {
        _searchController.clear();
      }
    });
  }

  Future<void> _showSortMenu() async {
    final selected = await showModalBottomSheet<SortOption>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _SortBottomSheet(currentSort: _currentSort),
    );

    if (selected != null && selected != _currentSort) {
      setState(() {
        _currentSort = selected;
      });
      await ref
          .read(libraryControllerProvider(widget.libraryType).notifier)
          .setSort(selected);
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
    final libraryData =
        ref.watch(libraryControllerProvider(widget.libraryType));
    final title =
        widget.libraryType == LibraryType.movies ? 'Movies' : 'TV Shows';
    final icon = widget.libraryType == LibraryType.movies
        ? Icons.movie_rounded
        : Icons.tv_rounded;
    final isDesktop = Breakpoints.isDesktop(context);

    // On desktop, always show search bar expanded
    final effectiveShowSearch = isDesktop || _showSearch;

    // Library grids use the calm static backdrop (no per-title artwork).
    publishBackdropSource(ref, BackdropSource.none);

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(title, icon, isDesktop, effectiveShowSearch),
      body: Column(
        children: [
          FreshnessHeader(
            queryKeys: [
              widget.libraryType == LibraryType.movies
                  ? QueryKeys.moviesList
                  : QueryKeys.tvShowsList,
            ],
            topInset: freshnessTopInset(
              context,
              appBarHeight: effectiveShowSearch ? 120 : kToolbarHeight,
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await ref
                    .read(
                        libraryControllerProvider(widget.libraryType).notifier)
                    .refresh();
              },
              child: libraryData.when(
                loading: () => _buildLoadingView(),
                error: (error, stackTrace) => _buildErrorView(error),
                data: (data) {
                  if (data.isEmpty) {
                    return _buildEmptyState();
                  }

                  // Filter items based on search query
                  final searchQuery =
                      _searchController.text.toLowerCase().trim();
                  final filteredItems = searchQuery.isEmpty
                      ? data.items
                      : data.items
                          .where((item) =>
                              item.title.toLowerCase().contains(searchQuery))
                          .toList();

                  if (filteredItems.isEmpty && searchQuery.isNotEmpty) {
                    return _buildNoSearchResultsState(searchQuery);
                  }

                  return _viewMode == ViewMode.grid
                      ? _buildGridView(context, filteredItems)
                      : _buildListView(context, filteredItems);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(
      String title, IconData icon, bool isDesktop, bool showSearch) {
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);

    return PreferredSize(
      preferredSize: Size.fromHeight(showSearch ? 120 : kToolbarHeight),
      child: GlassSurface.appBar(
        opacity: 0.85,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Main app bar
              SizedBox(
                height: kToolbarHeight,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                      horizontal: isDesktop ? horizontalPadding - 8 : 8),
                  child: Row(
                    children: [
                      // Hamburger menu on mobile
                      if (!isDesktop)
                        IconButton(
                          icon: const Icon(Icons.menu_rounded),
                          onPressed: () {
                            AppShell.scaffoldKey.currentState?.openDrawer();
                          },
                          tooltip: 'Menu',
                        ),
                      // Title with icon
                      Padding(
                        padding: EdgeInsets.only(left: isDesktop ? 8 : 0),
                        child: Row(
                          children: [
                            Icon(
                              icon,
                              color: AppColors.primary,
                              size: 24,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              title,
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: -0.3,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      // Action buttons - hide search toggle on desktop
                      if (!isDesktop)
                        _ActionButton(
                          icon: Icons.search_rounded,
                          isActive: _showSearch,
                          onPressed: _toggleSearch,
                          tooltip: 'Search',
                        ),
                      if (!isDesktop) const SizedBox(width: 4),
                      _ActionButton(
                        icon: Icons.sort_rounded,
                        onPressed: _showSortMenu,
                        tooltip: 'Sort: ${_currentSort.displayName}',
                      ),
                      const SizedBox(width: 4),
                      _ActionButton(
                        icon: _viewMode == ViewMode.grid
                            ? Icons.view_list_rounded
                            : Icons.grid_view_rounded,
                        onPressed: _toggleViewMode,
                        tooltip: 'Toggle view',
                      ),
                    ],
                  ),
                ),
              ),

              // Search bar (animated, always visible on desktop)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                height: showSearch ? 56 : 0,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: showSearch ? 1.0 : 0.0,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                        horizontalPadding, 0, horizontalPadding, 12),
                    child: TextField(
                      controller: _searchController,
                      autofocus: !isDesktop && _showSearch,
                      decoration: InputDecoration(
                        hintText: 'Search ${title.toLowerCase()}...',
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear_rounded, size: 18),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {});
                                },
                              )
                            : null,
                        filled: true,
                        fillColor:
                            AppColors.surfaceVariant.withValues(alpha: 0.5),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      onChanged: (value) {
                        setState(() {});
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingView() {
    return const Center(
      child: CircularProgressIndicator(),
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
                    .read(
                        libraryControllerProvider(widget.libraryType).notifier)
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
    final message = widget.libraryType == LibraryType.movies
        ? 'No movies yet'
        : 'No TV shows yet';
    final icon = widget.libraryType == LibraryType.movies
        ? Icons.movie_filter_rounded
        : Icons.live_tv_rounded;

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
                icon,
                size: 56,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              message,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Add content to your library to see it here',
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
            const SizedBox(height: 24),
            TextButton(
              onPressed: () {
                _searchController.clear();
                setState(() {});
              },
              child: const Text('Clear search'),
            ),
          ],
        ),
      ),
    );
  }

  double _getTopPadding(BuildContext context, bool showSearch) {
    final safeAreaTop = MediaQuery.of(context).padding.top;
    final appBarHeight = showSearch ? 120.0 : kToolbarHeight;
    return safeAreaTop + appBarHeight + 8;
  }

  Widget _buildGridView(BuildContext context, List items) {
    final isDesktop = Breakpoints.isDesktop(context);
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final cardSpacing = Breakpoints.getCardSpacing(context);
    final effectiveShowSearch = isDesktop || _showSearch;

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = _calculateCrossAxisCount(constraints.maxWidth);
        final topPadding = _getTopPadding(context, effectiveShowSearch);
        // Less bottom padding on desktop (no bottom nav)
        final bottomPadding = isDesktop ? 32.0 : 100.0;

        return GridView.builder(
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(
              horizontalPadding, topPadding, horizontalPadding, bottomPadding),
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
              progressPercentage: item.progressPercentage,
              isFavorite: item.isFavorite,
              onTap: () => _handleItemTap(item.id, item.type),
            );
          },
        );
      },
    );
  }

  Widget _buildListView(BuildContext context, List items) {
    final isDesktop = Breakpoints.isDesktop(context);
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final effectiveShowSearch = isDesktop || _showSearch;
    final topPadding = _getTopPadding(context, effectiveShowSearch);
    final bottomPadding = isDesktop ? 32.0 : 100.0;

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(
          horizontalPadding, topPadding, horizontalPadding, bottomPadding),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _ListItem(
          item: item,
          onTap: () => _handleItemTap(item.id, item.type),
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

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;
  final bool isActive;

  const _ActionButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: isActive
            ? AppColors.primary.withValues(alpha: 0.15)
            : AppColors.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onPressed,
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 20,
              color: isActive ? AppColors.primary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

class _ListItem extends StatelessWidget {
  final dynamic item;
  final VoidCallback onTap;

  const _ListItem({
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
                // Poster
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

                // Content
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

                // Favorite indicator
                if (item.isFavorite)
                  const Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: Icon(
                      Icons.favorite_rounded,
                      color: AppColors.error,
                      size: 20,
                    ),
                  ),

                // Chevron
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

class _SortBottomSheet extends StatelessWidget {
  final SortOption currentSort;

  const _SortBottomSheet({required this.currentSort});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textSecondary.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Title
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
              ],
            ),
          ),

          const Divider(height: 1),

          // Options
          ...SortOption.values.map((option) {
            final isSelected = option == currentSort;
            return ListTile(
              leading: Icon(
                isSelected ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: isSelected ? AppColors.primary : AppColors.textSecondary,
              ),
              title: Text(
                option.displayName,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected ? AppColors.primary : AppColors.textPrimary,
                ),
              ),
              onTap: () => Navigator.of(context).pop(option),
            );
          }),

          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
