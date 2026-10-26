library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/capabilities.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/theme/palette.dart';
import '../../../domain/sources/item.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/browse_grid.dart';
import '../../widgets/browse_scaffold.dart';
import '../../widgets/glass/glass_chip.dart';
import '../../widgets/horizontal_wheel_scroll.dart';
import '../../widgets/source_artwork.dart';
import '../detail/detail_links.dart';
import 'source_error_view.dart';

class SourceSearchNotifier extends Notifier<AsyncValue<List<ItemSummary>>?> {
  SourceSearchNotifier(this.sourceId);

  final SourceId sourceId;
  static const _debounce = Duration(milliseconds: 400);
  Timer? _timer;
  int _request = 0;
  String _lastQuery = '';

  @override
  AsyncValue<List<ItemSummary>>? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  void query(String text) {
    _timer?.cancel();
    // Any newer input outdates a search still in flight.
    _request++;
    final trimmed = text.trim();
    _lastQuery = trimmed;
    if (trimmed.isEmpty) {
      state = null;
      return;
    }
    _timer = Timer(_debounce, () => _run(trimmed));
  }

  /// Runs the last query again, for the error view's retry.
  void retry() {
    final text = _lastQuery;
    if (text.isNotEmpty) _run(text);
  }

  Future<void> _run(String text) async {
    final searchable =
        ref.read(mediaSourceProvider(sourceId))?.as<Searchable>();
    if (searchable == null) return;
    final request = ++_request;
    state = const AsyncLoading();
    try {
      final results = await searchable.search(text);
      if (ref.mounted && request == _request) state = AsyncData(results);
    } catch (e, st) {
      if (ref.mounted && request == _request) state = AsyncError(e, st);
    }
  }
}

final sourceSearchProvider = NotifierProvider.autoDispose
    .family<SourceSearchNotifier, AsyncValue<List<ItemSummary>>?, SourceId>(
        SourceSearchNotifier.new);

/// What the chips under the search box keep, by the result's own kind.
enum _KindFilter {
  all(Icons.search_rounded, null),
  movies(Icons.movie_rounded, ItemKind.movie),
  shows(Icons.tv_rounded, ItemKind.show),
  episodes(Icons.playlist_play_rounded, ItemKind.episode);

  const _KindFilter(this.icon, this.kind);

  final IconData icon;
  final ItemKind? kind;

  String label(AppLocalizations l10n) => switch (this) {
        all => l10n.sourcesSearchKindAll,
        movies => l10n.navMovies,
        shows => l10n.navShowsShort,
        episodes => l10n.sourcesSearchKindEpisodes,
      };

  List<ItemSummary> apply(List<ItemSummary> items) => kind == null
      ? items
      : [
          for (final item in items)
            if (item.ref.kind == kind) item,
        ];
}

class SourceSearchScreen extends ConsumerStatefulWidget {
  const SourceSearchScreen({
    super.key,
    required this.sourceId,
    this.initialQuery,
  });

  final SourceId sourceId;

  /// Fills the box and searches on first build, for a `?q=` link.
  final String? initialQuery;

  @override
  ConsumerState<SourceSearchScreen> createState() => _SourceSearchScreenState();
}

class _SourceSearchScreenState extends ConsumerState<SourceSearchScreen> {
  late final TextEditingController _controller;
  _KindFilter _kind = _KindFilter.all;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuery ?? '';
    _controller = TextEditingController(text: initial);
    if (initial.trim().isNotEmpty) {
      ref.read(sourceSearchProvider(widget.sourceId).notifier).query(initial);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sourceId = widget.sourceId;
    final results = ref.watch(sourceSearchProvider(sourceId));
    final notifier = ref.read(sourceSearchProvider(sourceId).notifier);
    final searchable =
        ref.watch(mediaSourceProvider(sourceId))?.as<Searchable>() != null;
    if (!searchable) {
      return BrowseScaffold(
        icon: Icons.search_rounded,
        title: context.l10n.navSearch,
        queryKeys: const [],
        body: (context, scrollTopPadding) => Center(
          child: Text(
            context.l10n.sourcesSearchUnsupported,
            key: const Key('source-search-unsupported'),
          ),
        ),
      );
    }
    return BrowseScaffold(
      icon: Icons.search_rounded,
      title: context.l10n.navSearch,
      queryKeys: const [],
      secondRow: Center(
        child: TextField(
          key: const Key('source-search-field'),
          controller: _controller,
          autofocus: true,
          style: const TextStyle(fontSize: 18),
          decoration: InputDecoration(
            hintText: context.l10n.sourcesSearchHint,
            hintStyle: TextStyle(
              color: context.palette.textSecondary.withValues(alpha: 0.6),
              fontSize: 18,
            ),
            // The app theme sets `filled: true`; the bar already draws the
            // surface, so the field is bare.
            filled: false,
            border: InputBorder.none,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            prefixIconConstraints: const BoxConstraints(minWidth: 32),
          ),
          textInputAction: TextInputAction.search,
          onChanged: notifier.query,
        ),
      ),
      body: (context, scrollTopPadding) => Column(
        children: [
          SizedBox(height: scrollTopPadding),
          _KindChips(
            selected: _kind,
            onSelected: (kind) => setState(() => _kind = kind),
          ),
          Expanded(
            child: switch (results) {
              null => const SizedBox.shrink(),
              AsyncData(:final value) => _results(_kind.apply(value)),
              AsyncError(:final error) =>
                SourceErrorView(error: error, onRetry: notifier.retry),
              _ => const Center(child: CircularProgressIndicator()),
            },
          ),
        ],
      ),
    );
  }

  Widget _results(List<ItemSummary> items) {
    if (items.isEmpty) {
      return Center(child: Text(context.l10n.sourcesSearchNothingFound));
    }
    return BrowseGrid(
      scrollTopPadding: 8,
      itemCount: items.length,
      itemBuilder: (context, index) => SourcePoster(
        key: ValueKey('source-poster-${items[index].ref.externalId}'),
        item: items[index],
        onTap: () => context.push(sourceItemLocation(items[index].ref)),
      ),
    );
  }
}

class _KindChips extends StatelessWidget {
  const _KindChips({required this.selected, required this.onSelected});

  final _KindFilter selected;
  final void Function(_KindFilter) onSelected;

  @override
  Widget build(BuildContext context) {
    return HorizontalWheelScroll(
      builder: (context, controller) => SingleChildScrollView(
        controller: controller,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: BackdropGroup(
          child: Row(
            children: [
              for (final kind in _KindFilter.values) ...[
                GlassChip(
                  chipKey: Key('source-search-kind-${kind.name}'),
                  avatar: Icon(kind.icon, size: 18),
                  label: Text(kind.label(context.l10n)),
                  selected: selected == kind,
                  onSelected: (_) => onSelected(kind),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
