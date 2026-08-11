import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/layout/dock_insets.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/models/search_result.dart';
import '../../widgets/browse_scaffold.dart';
import 'search_controller.dart';
import 'widgets/episode_result_row.dart';
import 'widgets/search_filter_chip.dart';
import 'widgets/search_result_card.dart';
import 'widgets/search_section_header.dart';

class SearchScreen extends ConsumerStatefulWidget {
  /// Seeds the text field from the `q` URL query parameter.
  final String? initialQuery;

  /// Pre-applies a section filter from the `type` URL query parameter.
  final SearchResultType? initialType;

  const SearchScreen({super.key, this.initialQuery, this.initialType});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchController = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Post-frame callbacks aren't cancelled on dispose. A synchronous route
      // redirect within the same frame can dispose this State before the
      // callback fires, and `ref`/`_focusNode` must not be touched after that.
      if (!mounted) return;
      _applyRouteParameters();
      if (widget.initialQuery == null || widget.initialQuery!.isEmpty) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The route stays mounted when only its query parameters change, which is
    // what a section's "Show all" does, so re-seed on parameter changes.
    if (oldWidget.initialQuery != widget.initialQuery ||
        oldWidget.initialType != widget.initialType) {
      // Defer to a post-frame callback: didUpdateWidget runs during the
      // widget tree's build phase, and Riverpod forbids modifying providers
      // (setTypes/updateQuery/search all do) until the frame is done — the
      // same reason initState defers its call instead of running it inline.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _applyRouteParameters();
      });
    }
  }

  /// Seeds controller state from `q` and `type` and runs the search.
  ///
  /// A route with no `q` — e.g. the sidebar's "Search" link, which always
  /// points at bare `/search` even while a filtered search is showing —
  /// resets the screen entirely instead of only clearing filters. Clearing
  /// filters alone left the text field and results grid still showing the
  /// previous filtered search underneath newly-deselected chips.
  void _applyRouteParameters() {
    final notifier = ref.read(searchControllerProvider.notifier);
    final query = widget.initialQuery ?? '';

    if (query.isEmpty) {
      _searchController.clear();
      notifier.clear();
      return;
    }

    notifier.setTypes(
      widget.initialType == null ? const {} : {widget.initialType!},
    );

    _searchController.text = query;
    notifier.updateQuery(query);
    notifier.search();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _focusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    ref.read(searchControllerProvider.notifier).updateQuery(value);

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 400), () {
      ref.read(searchControllerProvider.notifier).search();
    });
  }

  void _onClear() {
    _searchController.clear();
    ref.read(searchControllerProvider.notifier).clear();
    _focusNode.requestFocus();
  }

  void _onToggleType(SearchState searchState, SearchResultType type) {
    ref.read(searchControllerProvider.notifier).toggleType(type);
    if (searchState.query.isNotEmpty) {
      ref.read(searchControllerProvider.notifier).search();
    }
  }

  void _onShowAll(SearchState searchState, SearchResultType type) {
    final query = Uri.encodeQueryComponent(searchState.query);
    context.go('/search?q=$query&type=${type.queryValue}');
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchControllerProvider);

    return BrowseScaffold(
      icon: Icons.search_rounded,
      title: 'Search',
      queryKeys: const [],
      actions: [
        if (_searchController.text.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: _onClear,
            tooltip: 'Clear',
          ),
      ],
      secondRow: _buildSearchField(searchState),
      body: (context, scrollTopPadding) => Column(
        children: [
          SizedBox(height: scrollTopPadding),
          _buildFilterChips(searchState),
          Expanded(child: _buildBody(searchState)),
        ],
      ),
    );
  }

  Widget _buildSearchField(SearchState searchState) {
    return Center(
      child: TextField(
        controller: _searchController,
        focusNode: _focusNode,
        onChanged: _onSearchChanged,
        onSubmitted: (_) {
          _debounceTimer?.cancel();
          ref.read(searchControllerProvider.notifier).search();
        },
        style: const TextStyle(fontSize: 18),
        decoration: InputDecoration(
          hintText: 'Search your library...',
          hintStyle: TextStyle(
            color: AppColors.textSecondary.withValues(alpha: 0.6),
            fontSize: 18,
          ),
          // The app theme sets `filled: true` with a rounded fill.
          // `InputBorder.none` alone suppresses the stroke but not the fill,
          // which left this field rendering as a pill nobody designed, flush
          // against the chrome. Both have to be off.
          filled: false,
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          prefixIconConstraints: const BoxConstraints(minWidth: 32),
        ),
        textInputAction: TextInputAction.search,
      ),
    );
  }

  static const _chipIcons = {
    SearchResultType.movie: Icons.movie_rounded,
    SearchResultType.tvShow: Icons.tv_rounded,
    SearchResultType.episode: Icons.playlist_play_rounded,
    SearchResultType.collection: Icons.collections_bookmark_rounded,
  };

  Widget _buildFilterChips(SearchState searchState) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          for (final type in SearchResultType.values) ...[
            SearchFilterChip(
              label: type.sectionTitle,
              icon: _chipIcons[type] ?? Icons.search_rounded,
              isSelected: searchState.selectedTypes.contains(type),
              onTap: () => _onToggleType(searchState, type),
            ),
            const SizedBox(width: 8),
          ],
          if (searchState.selectedTypes.isNotEmpty)
            TextButton(
              onPressed: () {
                ref.read(searchControllerProvider.notifier).clearFilters();
                if (searchState.query.isNotEmpty) {
                  ref.read(searchControllerProvider.notifier).search();
                }
              },
              child: const Text('Clear filters'),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(SearchState searchState) {
    // Initial state - show prompt
    if (searchState.query.isEmpty && searchState.results == null) {
      return _buildInitialState();
    }

    // Loading state
    if (searchState.isLoading) {
      return _buildLoadingState();
    }

    // Error state
    if (searchState.error != null) {
      return _buildErrorState(searchState.error!);
    }

    // Empty results
    if (searchState.isEmpty) {
      return _buildEmptyState(searchState.query);
    }

    // Show results
    if (searchState.hasResults) {
      return _buildSections(searchState, searchState.results!);
    }

    return _buildInitialState();
  }

  Widget _buildInitialState() {
    return Center(
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
              Icons.search_rounded,
              size: 64,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Search your library',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Movies, shows, episodes, and collections',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary.withValues(alpha: 0.7),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text(
            'Searching...',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(String error) {
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
              'Search failed',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                ref.read(searchControllerProvider.notifier).search();
              },
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(String query) {
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
                size: 64,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'No results found',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'No matches for "$query"',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Try a different search term or adjust filters',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary.withValues(alpha: 0.7),
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSections(SearchState searchState, SearchResults results) {
    return CustomScrollView(
      slivers: [
        for (final section in results.sections) ...[
          SliverToBoxAdapter(
            child: SearchSectionHeader(
              title: section.type.sectionTitle,
              count: section.totalCount,
              onShowAll: section.totalCount > section.results.length
                  ? () => _onShowAll(searchState, section.type)
                  : null,
            ),
          ),
          if (section.type == SearchResultType.episode)
            SliverList.builder(
              itemCount: section.results.length,
              itemBuilder: (context, index) {
                final result = section.results[index];
                return EpisodeResultRow(
                  key: ValueKey(result.id),
                  result: result,
                  onTap: () => context.push(result.routePath),
                );
              },
            )
          else
            // `SliverLayoutBuilder`, not `MediaQuery`: on desktop `AppShell`
            // puts a fixed 260px `DesktopSidebar` beside this screen, so the
            // window is wider than the content area. Counting columns from
            // the window overestimates the space and cramps every card.
            // `crossAxisExtent` here is the viewport's, measured outside the
            // padding below, which matches how `BrowseGrid` reads
            // `constraints.maxWidth` so both grids bucket identically.
            SliverLayoutBuilder(
              builder: (context, sliverConstraints) => SliverPadding(
                padding: EdgeInsets.symmetric(
                  horizontal: Breakpoints.getHorizontalPadding(context),
                ),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: libraryCrossAxisCount(
                      sliverConstraints.crossAxisExtent,
                    ),
                    childAspectRatio: 0.58,
                    crossAxisSpacing: Breakpoints.getCardSpacing(context),
                    mainAxisSpacing: Breakpoints.getCardSpacing(context) + 4,
                  ),
                  itemCount: section.results.length,
                  itemBuilder: (context, index) {
                    final result = section.results[index];
                    return SearchResultCard(
                      key: ValueKey(result.id),
                      result: result,
                      onTap: () => context.push(result.routePath),
                    );
                  },
                ),
              ),
            ),
        ],
        const SliverDockGap(),
      ],
    );
  }
}
