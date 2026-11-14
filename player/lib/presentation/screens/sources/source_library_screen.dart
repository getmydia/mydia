library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/cache/invalidation_target.dart';
import '../../../core/cache/watcher_registry.dart';
import '../../../core/focus/focus_memory.dart';
import '../../../core/layout/breakpoints.dart';
import '../../../core/layout/dock_insets.dart';
import '../../../core/player/input_capabilities.dart';
import '../../../core/settings/settings_providers.dart';
import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/media_source.dart' show SourceCapability;
import '../../../domain/navigation/media_filter.dart';
import '../filter/filter_editor_sheet.dart';
import '../library/library_sort.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/theme/palette.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../../../l10n/l10n.dart';
import '../../../core/sources/source.dart' show SourceKind;
import '../../widgets/browse_grid.dart';
import '../../../core/sources/files/files_scan_controller.dart';
import '../../../core/sources/files/peer_files_sources.dart'
    show refreshPeerFilesSources;
import '../../widgets/files/files_scan_banner.dart';
import '../../widgets/browse_scaffold.dart';
import '../../widgets/glass/glass_chip.dart';
import '../../widgets/source_artwork.dart';
import '../detail/detail_links.dart';
import 'source_browse_providers.dart';
import 'source_error_view.dart';
import 'source_listing_screen.dart' show sourceSearchActions;
import 'source_pages.dart';

enum _ViewMode { grid, list }

/// Remembered sorts decoded this session, by `<sourceId>/<libraryId>`. A key
/// present with a null value means storage held nothing. Lives for the app
/// session, so only the first visit to a library can wait on storage.
final rememberedSortsProvider =
    Provider<Map<String, BrowseQuery?>>((ref) => {});

SortOption? _sortOption(Library info, BrowseQuery query) {
  final options = info.sortOptions;
  return options.where((o) => o.id == query.sortId).firstOrNull ??
      options.firstOrNull;
}

/// `<sortId>|asc`, `<sortId>|desc`, or `<sortId>|` for the sort's own order.
String _encodeSort(BrowseQuery query) =>
    '${query.sortId ?? ''}|${switch (query.descending) {
      null => '',
      true => 'desc',
      false => 'asc',
    }}';

BrowseQuery? _decodeSort(String? raw) {
  if (raw == null) return null;
  final split = raw.lastIndexOf('|');
  if (split <= 0) return null;
  return BrowseQuery(
    sortId: raw.substring(0, split),
    descending: switch (raw.substring(split + 1)) {
      'desc' => true,
      'asc' => false,
      _ => null,
    },
  );
}

/// A library of any source: sort and filter chips over a poster grid, or a
/// list. Saved filters open it with an [initialQuery] and the filter's
/// [title].
class SourceLibraryScreen extends ConsumerStatefulWidget {
  const SourceLibraryScreen({
    super.key,
    required this.library,
    this.initialQuery,
    this.title,
    this.icon,
    this.actions = const [],
    this.canSaveAsFilter = true,
  });

  final LibraryRef library;

  /// False where the screen supplies its own save menu, as a saved filter does.
  final bool canSaveAsFilter;

  /// Title-bar actions placed before the view toggle.
  final List<Widget> actions;

  /// Seeds the library's query on first build, when it still holds the
  /// default. Later changes are the viewer's and are never overwritten.
  final BrowseQuery? initialQuery;

  /// Replaces the library's own title, as a saved filter's label does.
  final String? title;

  /// Replaces the glyph beside the title.
  final IconData? icon;

  @override
  ConsumerState<SourceLibraryScreen> createState() =>
      _SourceLibraryScreenState();
}

class _SourceLibraryScreenState extends ConsumerState<SourceLibraryScreen> {
  static const _defaultQuery = BrowseQuery();

  _ViewMode _viewMode = _ViewMode.grid;
  bool _seeded = false;

  /// Keeps the list's state (scroll, focus) when [_withScanBanner] changes
  /// the widget that wraps it.
  final _contentKey = GlobalKey();

  /// A plain library remembers its sort across visits; a saved filter's own
  /// query wins and is never stored.
  bool get _remembers => widget.initialQuery == null;

  String get _sortKey =>
      '${widget.library.sourceId.value}/${widget.library.id}';

  /// True until the remembered sort has been read, so the library never
  /// fetches under the default and then again under the stored order.
  late bool _loadingSort = _remembers && !_cache.containsKey(_sortKey);

  /// Sorts already read this session, so a repeat visit needs no storage.
  late final Map<String, BrowseQuery?> _cache =
      ref.read(rememberedSortsProvider);

  /// The query a first build starts from: a saved filter's, else the
  /// remembered sort when this session already knows it.
  BrowseQuery? get _seed =>
      widget.initialQuery ?? (_remembers ? _cache[_sortKey] : null);

  /// How long the first storage read may hold the library back.
  static const _readTimeout = Duration(milliseconds: 300);

  @override
  void initState() {
    super.initState();
    if (_loadingSort) _loadSort();
    // A provider cannot be written while the tree builds, so the seed lands
    // after it; `build` already answers with the seed until then, so the
    // first fetch is the right one.
    Future.microtask(() {
      if (!mounted) return;
      _seeded = true;
      final initial = _seed;
      final notifier = ref.read(libraryQueryProvider(widget.library).notifier);
      if (initial != null &&
          ref.read(libraryQueryProvider(widget.library)) == _defaultQuery) {
        notifier.set(initial);
      }
    });
  }

  Future<void> _loadSort() async {
    BrowseQuery? stored;
    var answered = false;
    try {
      final raw = await ref
          .read(coreSettingsServiceProvider)
          .getLibrarySort(_sortKey)
          .timeout(_readTimeout);
      stored = _decodeSort(raw);
      answered = true;
    } catch (_) {
      // A stalled or unreadable preference is the default order, not an
      // error. A late answer is dropped: the first page is already up.
    }
    if (!mounted) return;
    if (answered) _cache.putIfAbsent(_sortKey, () => stored);
    if (stored != null &&
        ref.read(libraryQueryProvider(widget.library)) == _defaultQuery) {
      ref.read(libraryQueryProvider(widget.library).notifier).set(stored);
    }
    setState(() => _loadingSort = false);
  }

  Future<void> _setQuery(BrowseQuery query) async {
    ref.read(libraryQueryProvider(widget.library).notifier).set(query);
    if (!_remembers) return;
    _cache[_sortKey] = query;
    try {
      await ref
          .read(coreSettingsServiceProvider)
          .setLibrarySort(_sortKey, _encodeSort(query));
    } catch (_) {
      // The order still applies for this visit.
    }
  }

  /// Opens the filter editor on this library's kind and the current sort.
  void _saveAsFilter(Library info, BrowseQuery query) {
    final kind = switch (info.kind) {
      LibraryKind.movies => MediaKind.movies,
      LibraryKind.shows => MediaKind.shows,
      LibraryKind.videos => null,
    };
    if (kind == null) return;
    final option = _sortOption(info, query);
    final field = SortField.fromWireName(query.sortId ?? option?.id ?? '') ??
        LibrarySort.defaultSort.field;
    final descending = query.descending ??
        option?.descendingByDefault ??
        LibrarySort.defaultSort.direction == SortDirection.desc;
    showFilterEditor(
      context: context,
      ref: ref,
      initialFilter: MediaFilter(
        kind: kind,
        category: null,
        watch: WatchScope.all,
        sort: LibrarySort(
          field: field,
          direction: descending ? SortDirection.desc : SortDirection.asc,
        ),
      ),
    );
  }

  BrowseQuery _effective(BrowseQuery stored) {
    final initial = _seed;
    return !_seeded && initial != null && stored == _defaultQuery
        ? initial
        : stored;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final library = widget.library;
    final libraries = ref.watch(sourceLibrariesProvider(library.sourceId));
    final info = switch (libraries) {
      AsyncData(:final value) =>
        value.where((l) => l.ref == library).firstOrNull,
      _ => null,
    };
    final query = _effective(ref.watch(libraryQueryProvider(library)));
    final pages = LibraryPages(library, query);
    // Held back while the remembered sort loads: a fetch under the default
    // order would be thrown away a moment later.
    final browse = _loadingSort
        ? const AsyncLoading<PagedItems>()
        : ref.watch(sourcePagesProvider(pages));
    final key = SourceKeys.browse(library, query);
    final isList = _viewMode == _ViewMode.list;
    final isShows = info?.kind == LibraryKind.shows;
    final sort = info == null ? null : _sortOption(info, query);
    final descending = query.descending ?? sort?.descendingByDefault ?? false;
    final canSaveFilter = info != null &&
        widget.canSaveAsFilter &&
        info.kind != LibraryKind.videos &&
        (ref
                .watch(mediaSourceProvider(library.sourceId))
                ?.capabilities
                .contains(SourceCapability.savedFilters) ??
            false);

    return BrowseScaffold(
      icon: widget.icon ?? (isShows ? Icons.tv_rounded : Icons.movie_rounded),
      title:
          widget.title ?? (info == null ? '' : context.l10n.libraryTitle(info)),
      queryKeys: [key],
      actions: [
        ...widget.actions,
        ...sourceSearchActions(context, library.sourceId),
        if (sort != null)
          IconButton(
            key: const Key('source-sort-direction'),
            icon: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: palette.surfaceVariant.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                descending
                    ? Icons.arrow_downward_rounded
                    : Icons.arrow_upward_rounded,
                size: 20,
              ),
            ),
            tooltip: descending
                ? context.l10n.sourcesLibrarySortDescending
                : context.l10n.sourcesLibrarySortAscending,
            onPressed: () => _setQuery(query.copyWith(descending: !descending)),
          ),
        IconButton(
          key: const Key('source-view-toggle'),
          icon: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: palette.surfaceVariant.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              isList ? Icons.grid_view_rounded : Icons.view_list_rounded,
              size: 20,
            ),
          ),
          tooltip: context.l10n.sourcesLibraryToggleView,
          onPressed: () => setState(
              () => _viewMode = isList ? _ViewMode.grid : _ViewMode.list),
        ),
        if (canSaveFilter)
          PopupMenuButton<String>(
            key: const Key('source-library-menu'),
            icon: Icon(
              Icons.more_vert_rounded,
              color: palette.textSecondary,
              size: 22,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
            color: palette.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onSelected: (value) {
              if (value == 'save_filter') _saveAsFilter(info, query);
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'save_filter',
                child: Text(context.l10n.sourcesLibrarySaveFilter),
              ),
            ],
          ),
      ],
      secondRow: info == null
          ? null
          : _ChipRow(
              info: info,
              query: query,
              onChanged: _setQuery,
            ),
      onRefresh: () async {
        // A library a paired player lends refetches the host's index first,
        // so the browse below reads the new copy.
        await refreshPeerFilesSources(ref.read, [library.sourceId]);
        await ref.read(invalidatorProvider).invalidate([key.target]);
      },
      body: (context, scrollTopPadding) => _withScanBanner(
          scrollTopPadding,
          (scrollTopPadding) => switch (browse) {
                AsyncData(:final value) when value.items.isEmpty => _EmptyState(
                    title: isShows
                        ? context.l10n.sourcesLibraryEmptyShows
                        : context.l10n.sourcesLibraryEmptyMovies,
                    icon: isShows
                        ? Icons.live_tv_rounded
                        : Icons.movie_filter_rounded,
                  ),
                AsyncData(:final value) =>
                  NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.extentAfter < 800) {
                        ref
                            .read(sourcePagesProvider(pages).notifier)
                            .loadMore();
                      }
                      return false;
                    },
                    child: isList
                        ? _ItemList(
                            items: value.items,
                            scrollTopPadding: scrollTopPadding,
                          )
                        : BrowseGrid(
                            scrollTopPadding: scrollTopPadding,
                            itemCount: value.items.length,
                            itemId: (index) => value.items[index].ref,
                            itemBuilder: (context, index) {
                              final item = value.items[index];
                              return SourcePoster(
                                key: ValueKey(
                                    'source-poster-${item.ref.externalId}'),
                                item: item,
                                onTap: () =>
                                    context.push(sourceItemLocation(item.ref)),
                              );
                            },
                          ),
                  ),
                AsyncError(:final error) => SourceErrorView(
                    error: error,
                    account: ref
                        .watch(mediaSourceProvider(library.sourceId))
                        ?.source
                        .account,
                    onRetry: () => ref.invalidate(sourcePagesProvider(pages)),
                  ),
                _ => const Center(child: CircularProgressIndicator()),
              }),
    );
  }

  /// Files libraries show scan progress above the list while a scan runs,
  /// and after one that skipped folders, in its own band, so it never covers
  /// the first rows. [content] is built
  /// with the top padding its scroll view should keep.
  Widget _withScanBanner(double top, Widget Function(double top) content) {
    final sourceId = widget.library.sourceId;
    final source = ref.watch(mediaSourceProvider(sourceId));
    if (source?.kind != SourceKind.files ||
        !filesScanBannerShows(ref.watch(filesScanProvider(sourceId)))) {
      return KeyedSubtree(key: _contentKey, child: content(top));
    }
    return Column(
      children: [
        SizedBox(height: top),
        Material(
          color: context.palette.surface,
          child: FilesScanBanner(sourceId: sourceId),
        ),
        Expanded(child: KeyedSubtree(key: _contentKey, child: content(0))),
      ],
    );
  }
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.info,
    required this.query,
    required this.onChanged,
  });

  final Library info;
  final BrowseQuery query;
  final void Function(BrowseQuery) onChanged;

  @override
  Widget build(BuildContext context) {
    final sorts = info.sortOptions.length;
    return BackdropGroup(
      // Sort and filter ids are separate namespaces, so each chip's memory
      // id says which kind it is.
      child: FocusMemoryRegion(
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final (index, option) in info.sortOptions.indexed)
              FocusMemoryItem(
                id: ('sort', option.id),
                index: index,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GlassChip(
                    chipKey: Key('source-sort-${option.id}'),
                    label: Text(context.l10n.sortName(option.name)),
                    selected: (query.sortId ?? info.sortOptions.first.id) ==
                        option.id,
                    // A new sort starts in its own default direction.
                    onSelected: (_) => onChanged(BrowseQuery(
                      sortId: option.id,
                      filterIds: query.filterIds,
                      pageSize: query.pageSize,
                    )),
                  ),
                ),
              ),
            for (final (index, filter) in info.filterOptions.indexed)
              FocusMemoryItem(
                id: ('filter', filter.id),
                index: sorts + index,
                child: Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GlassChip(
                    multiSelect: true,
                    chipKey: Key('source-filter-${filter.id}'),
                    label: Text(context.l10n.filterOptionName(filter)),
                    selected: query.filterIds.contains(filter.id),
                    onSelected: (on) => onChanged(query.copyWith(
                      filterIds: on
                          ? {...query.filterIds, filter.id}
                          : ({...query.filterIds}..remove(filter.id)),
                    )),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ItemList extends StatelessWidget {
  const _ItemList({required this.items, required this.scrollTopPadding});

  final List<ItemSummary> items;
  final double scrollTopPadding;

  @override
  Widget build(BuildContext context) {
    final horizontalPadding = Breakpoints.getHorizontalPadding(context);
    final directional = InputCapabilities.directionalPrimary;
    final list = ListView.builder(
      key: const Key('source-library-list'),
      padding: EdgeInsets.fromLTRB(horizontalPadding, scrollTopPadding,
          horizontalPadding, DockInsets.bottomOf(context)),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final row = _ListRow(item: items[index]);
        // Keyed by the item, as the grid view's posters are, so coming back
        // from the chip bar returns to the row that left rather than the
        // row nearest the chip.
        return directional
            ? FocusMemoryItem(id: items[index].ref, index: index, child: row)
            : row;
      },
    );
    // A one-column list: a first entry lands on the first row on screen,
    // not on one built above the viewport.
    return directional
        ? FocusMemoryRegion(
            entry: FocusMemoryEntry.firstVisible,
            // The list view's rows are what the page is for, as the grid's
            // posters are.
            landing: true,
            debugLabel: 'source-library-list',
            child: list,
          )
        : list;
  }
}

class _ListRow extends StatelessWidget {
  const _ListRow({required this.item});

  final ItemSummary item;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final caption = item.subtitle ?? item.year?.toString();
    final fallback = Container(
      color: palette.surfaceVariant,
      child: Icon(Icons.movie_outlined, color: palette.textSecondary),
    );
    final poster = item.poster;
    return Padding(
      key: ValueKey('source-list-${item.ref.externalId}'),
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => context.push(sourceItemLocation(item.ref)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 60,
                    height: 90,
                    child: poster == null
                        ? fallback
                        : SourceArtworkImage(
                            sourceId: item.ref.sourceId,
                            art: poster,
                            fallback: fallback,
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
                      if (caption != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          caption,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: palette.textSecondary,
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                if (item.userState.watched)
                  Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Icon(
                      Icons.check_circle_rounded,
                      color: palette.textSecondary,
                      size: 20,
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: palette.textSecondary,
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: palette.primary.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 56, color: palette.primary),
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
              context.l10n.sourcesLibraryEmptyHint,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: palette.textSecondary,
                  ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
