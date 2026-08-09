import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../domain/navigation/media_filter.dart';
import 'library_controller.dart';
import 'library_grid_body.dart';
import 'library_sort.dart';
import 'library_sort_provider.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/app_shell.dart';
import '../../widgets/cast_actions.dart';
import '../../widgets/cast_button.dart';
import '../../widgets/freshness_header.dart';
import '../../widgets/glass_surface.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/colors.dart';

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
  LibraryViewMode _viewMode = LibraryViewMode.grid;
  bool _showSearch = false;

  /// Height of the search row when it is expanded. Matches the
  /// `AnimatedContainer` in `_buildAppBar` below.
  static const double _searchRowHeight = 56;

  /// The app bar's settled height, excluding the status bar inset.
  ///
  /// The single source of truth for three call sites that used to carry their
  /// own copy: `preferredSize`, the freshness inset, and the scroll padding.
  /// The old copies all said 120 while the bar actually builds 112.
  double _barHeight(bool showSearch) =>
      kToolbarHeight + (showSearch ? _searchRowHeight : 0);

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  MediaFilter _mediaFilter(LibrarySort sort) => MediaFilter(
        kind: widget.libraryType == LibraryType.movies
            ? MediaKind.movies
            : MediaKind.shows,
        category: null,
        watch: WatchScope.all,
        sort: sort,
      );

  void _toggleViewMode() {
    setState(() {
      _viewMode = _viewMode == LibraryViewMode.grid
          ? LibraryViewMode.list
          : LibraryViewMode.grid;
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
    final sort =
        ref.read(librarySortControllerProvider(widget.libraryType)).value ??
            LibrarySort.defaultSort;

    final selected = await showModalBottomSheet<_SortSelection>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _SortBottomSheet(currentSort: sort),
    );

    if (selected == null || !mounted) return;

    final controller = ref.read(
      librarySortControllerProvider(widget.libraryType).notifier,
    );

    if (selected.toggleOnly) {
      await controller.toggleDirection();
    } else if (selected.field != null) {
      await controller.select(selected.field!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sortAsync = ref.watch(
      librarySortControllerProvider(widget.libraryType),
    );

    // Wait for the persisted sort before querying, so the library never
    // mounts under the default and then re-queries under the stored order.
    final sort = sortAsync.value;
    if (sort == null) {
      return const Center(child: CircularProgressIndicator());
    }

    final filter = _mediaFilter(sort);
    final title =
        widget.libraryType == LibraryType.movies ? 'Movies' : 'TV Shows';
    final icon = widget.libraryType == LibraryType.movies
        ? Icons.movie_rounded
        : Icons.tv_rounded;
    final isDesktop = Breakpoints.isDesktop(context);

    // On desktop, always show search bar expanded
    final effectiveShowSearch = isDesktop || _showSearch;

    final barHeight = _barHeight(effectiveShowSearch);
    // Read MediaQuery *here*, above the `Scaffold`. Inside the body of a
    // `Scaffold(extendBodyBehindAppBar: true)` Flutter rewrites `padding.top`
    // to the app bar's own bottom edge (see `_BodyBuilder` in
    // material/scaffold.dart), so any descendant that reads it and adds
    // `barHeight` again counts the bar twice. That was this screen's bug: the
    // grid read it from a `LayoutBuilder` inside the body and sat 128px too
    // low, while the list read it from this context and was nearly right.
    final chromeTop = freshnessTopInset(context, appBarHeight: barHeight);
    final scrollTopPadding = chromeTop + 8;

    // Library grids use the calm static backdrop (no per-title artwork).
    publishBackdropSource(ref, BackdropSource.none);

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(
          title, icon, isDesktop, effectiveShowSearch, barHeight, sort),
      // A `Stack`, not a `Column`: `FreshnessHeader` carries a top inset that
      // exists purely to clear an app bar this body already extends behind. As
      // a `Column` sibling that inset was charged as layout height too, so
      // every background refetch shoved the whole grid down by ~161px on top
      // of its own padding. Overlaying keeps the header in the same pixels
      // without it owning any of the scroll view's space.
      body: LibraryMediaBody(
        filter: filter,
        scrollController: _scrollController,
        chromeTop: chromeTop,
        scrollTopPadding: scrollTopPadding,
        viewMode: _viewMode,
        emptyTitle: widget.libraryType == LibraryType.movies
            ? 'No movies yet'
            : 'No TV shows yet',
        emptySubtitle: 'Add content to your library to see it here',
        emptyIcon: widget.libraryType == LibraryType.movies
            ? Icons.movie_filter_rounded
            : Icons.live_tv_rounded,
        searchQuery: _searchController.text,
        onSearchClear: () {
          _searchController.clear();
          setState(() {});
        },
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(String title, IconData icon, bool isDesktop,
      bool showSearch, double barHeight, LibrarySort sort) {
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);

    return PreferredSize(
      preferredSize: Size.fromHeight(barHeight),
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
                        tooltip: 'Sort: ${sort.field.displayName}'
                            '${sort.field.supportsDirection ? ' (${sort.direction == SortDirection.asc ? 'Asc' : 'Desc'})' : ''}',
                      ),
                      const SizedBox(width: 4),
                      _ActionButton(
                        icon: _viewMode == LibraryViewMode.grid
                            ? Icons.view_list_rounded
                            : Icons.grid_view_rounded,
                        onPressed: _toggleViewMode,
                        tooltip: 'Toggle view',
                      ),
                      const SizedBox(width: 4),
                      // LibraryScreen keeps a real app bar on every platform
                      // (unlike the desktop-suppressed browse screens), so it
                      // carries its own cast affordance instead of the
                      // shell's overlay — see AppShell._hasOwnCastButton.
                      CastButton(
                        onPressed: () => pickCastDevice(context, ref),
                      ),
                    ],
                  ),
                ),
              ),

              // Search bar (animated, always visible on desktop)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                height: showSearch ? _searchRowHeight : 0,
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

class _SortBottomSheet extends StatelessWidget {
  final LibrarySort currentSort;

  const _SortBottomSheet({required this.currentSort});

  @override
  Widget build(BuildContext context) {
    final directionEnabled = currentSort.field.supportsDirection;

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

          // Title and direction toggle
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
                const Spacer(),
                TextButton.icon(
                  key: const Key('sort-direction-toggle'),
                  onPressed: directionEnabled
                      ? () => Navigator.of(context).pop(
                            const _SortSelection.toggleDirection(),
                          )
                      : null,
                  icon: Icon(
                    currentSort.direction == SortDirection.asc
                        ? Icons.arrow_upward_rounded
                        : Icons.arrow_downward_rounded,
                    size: 18,
                  ),
                  label: Text(
                    currentSort.direction == SortDirection.asc ? 'Asc' : 'Desc',
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Fields
          ...SortField.values.map((field) {
            final isSelected = field == currentSort.field;
            return ListTile(
              key: Key('sort-field-${field.wireName}'),
              leading: Icon(
                isSelected ? Icons.check_circle_rounded : Icons.circle_outlined,
                color: isSelected ? AppColors.primary : AppColors.textSecondary,
              ),
              title: Text(
                field.displayName,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected ? AppColors.primary : AppColors.textPrimary,
                ),
              ),
              onTap: () =>
                  Navigator.of(context).pop(_SortSelection.field(field)),
            );
          }),

          const SizedBox(height: 20),
        ],
      ),
    );
  }
}

/// What the sort sheet returns: either a chosen field, or a request to flip
/// direction without changing field.
class _SortSelection {
  const _SortSelection.field(this.field) : toggleOnly = false;
  const _SortSelection.toggleDirection()
      : field = null,
        toggleOnly = true;

  final SortField? field;
  final bool toggleOnly;
}
