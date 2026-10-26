import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/theme/liquid_glass/glass_style.dart';
import '../../../core/theme/palette.dart';
import '../../../domain/navigation/media_filter.dart';
import '../../../domain/navigation/nav_destination.dart';
import '../../../l10n/l10n.dart';
import '../library/library_sort.dart';
import '../../widgets/glass/glass_sheet.dart';
import '../library/library_sort_sheet.dart';

/// Opens the filter create/edit sheet.
Future<void> showFilterEditor({
  required BuildContext context,
  required WidgetRef ref,
  MediaFilter? initialFilter,
  FilterDestination? editing,
}) {
  return showGlassSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) => FilterEditorSheet(
      initialFilter: initialFilter ?? MediaFilter.allMovies,
      editing: editing,
      onSave: (destination) async {
        final controller = ref.read(sidebarLayoutControllerProvider);
        if (editing != null) {
          await controller.updateFilter(destination);
        } else {
          await controller.addFilter(destination);
        }
        if (sheetContext.mounted) {
          Navigator.of(sheetContext).pop();
        }
      },
    ),
  );
}

class FilterEditorSheet extends StatefulWidget {
  const FilterEditorSheet({
    super.key,
    required this.initialFilter,
    required this.editing,
    required this.onSave,
  });

  final MediaFilter initialFilter;
  final FilterDestination? editing;
  final Future<void> Function(FilterDestination destination) onSave;

  @override
  State<FilterEditorSheet> createState() => _FilterEditorSheetState();
}

class _FilterEditorSheetState extends State<FilterEditorSheet> {
  late final TextEditingController _nameController;
  late MediaFilter _filter;
  String? _nameError;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.editing?.label);
    _filter = widget.initialFilter;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _setKind(MediaKind kind) {
    if (kind == _filter.kind) return;
    setState(() {
      _filter = _filter.copyWith(kind: kind, clearCategory: true);
    });
  }

  void _setCategory(MediaCategoryFilter? category) {
    setState(() {
      _filter = category == null
          ? _filter.copyWith(clearCategory: true)
          : _filter.copyWith(category: category);
    });
  }

  void _setWatch(WatchScope watch) {
    setState(() => _filter = _filter.copyWith(watch: watch));
  }

  Future<void> _showSortPicker() async {
    final selected = await showGlassSheet<LibrarySortSelection>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => LibrarySortSheet(currentSort: _filter.sort),
    );

    if (selected == null) return;

    setState(() {
      if (selected.toggleOnly) {
        final current = _filter.sort;
        if (current.field.supportsDirection) {
          _filter = _filter.copyWith(
            sort: current.copyWith(direction: current.direction.flipped),
          );
        }
      } else if (selected.field != null) {
        final current = _filter.sort;
        _filter = _filter.copyWith(
          sort: selected.field == SortField.random
              ? LibrarySort(
                  field: SortField.random,
                  direction: current.direction,
                  randomSeed: DateTime.now().microsecondsSinceEpoch,
                )
              : LibrarySort(
                  field: selected.field!,
                  direction: current.direction,
                ),
        );
      }
    });
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _nameError = context.l10n.filterEditorNameRequired);
      return;
    }

    final id =
        widget.editing?.id ?? 'f_${DateTime.now().microsecondsSinceEpoch}';

    await widget.onSave(
      FilterDestination(
        id: id,
        label: name,
        filter: _filter,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final categories = MediaCategoryFilter.forKind(_filter.kind);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Material(
        key: const Key('filter-editor-surface'),
        // On Liquid Glass the sheet sits on glass from showGlassSheet; an opaque
        // fill here would hide it.
        color: GlassStyle.of(context) ? Colors.transparent : palette.surface,
        borderRadius: GlassStyle.of(context)
            ? null
            : const BorderRadius.vertical(top: Radius.circular(20)),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  alignment: Alignment.center,
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: palette.textSecondary.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(
                    widget.editing == null
                        ? context.l10n.navNewFilter
                        : context.l10n.filterEditorEditTitle,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: TextField(
                    key: const Key('filter-editor-name'),
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: context.l10n.filterEditorName,
                      errorText: _nameError,
                    ),
                    onChanged: (_) {
                      if (_nameError != null) {
                        setState(() => _nameError = null);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: SegmentedButton<MediaKind>(
                    segments: [
                      ButtonSegment(
                        value: MediaKind.movies,
                        label: Text(context.l10n.navMovies),
                      ),
                      ButtonSegment(
                        value: MediaKind.shows,
                        label: Text(context.l10n.navShows),
                      ),
                    ],
                    selected: {_filter.kind},
                    onSelectionChanged: (selection) =>
                        _setKind(selection.first),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  // initialValue is read once, so changing the kind (which
                  // swaps the categories and clears the selection) must
                  // rebuild the field.
                  child: KeyedSubtree(
                    key: ValueKey(_filter.kind),
                    child: DropdownButtonFormField<MediaCategoryFilter?>(
                      key: const Key('filter-editor-category'),
                      initialValue: _filter.category,
                      decoration: InputDecoration(
                          labelText: context.l10n.filterEditorCategory),
                      items: [
                        DropdownMenuItem(
                          value: null,
                          child: Text(context.l10n.commonAll),
                        ),
                        for (final category in categories)
                          DropdownMenuItem(
                            value: category,
                            child:
                                Text(context.l10n.categoryFilterName(category)),
                          ),
                      ],
                      onChanged: _setCategory,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: SegmentedButton<WatchScope>(
                    segments: [
                      ButtonSegment(
                        value: WatchScope.all,
                        label: Text(context.l10n.commonAll),
                      ),
                      ButtonSegment(
                        value: WatchScope.unwatched,
                        label: Text(context.l10n.navUnwatched),
                      ),
                      ButtonSegment(
                        value: WatchScope.favorites,
                        label: Text(context.l10n.navFavorites),
                      ),
                    ],
                    selected: {_filter.watch},
                    onSelectionChanged: (selection) =>
                        _setWatch(selection.first),
                  ),
                ),
                const SizedBox(height: 8),
                ListTile(
                  leading: const Icon(Icons.sort_rounded),
                  title: Text(context.l10n.filterEditorSort),
                  subtitle:
                      Text(context.l10n.sortFieldName(_filter.sort.field)),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _showSortPicker,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: FilledButton(
                    key: const Key('filter-editor-save'),
                    onPressed: _save,
                    child: Text(context.l10n.commonSave),
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
