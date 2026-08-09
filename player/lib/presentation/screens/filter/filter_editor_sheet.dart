import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/navigation/media_filter.dart';
import '../../../domain/navigation/nav_destination.dart';
import '../library/library_sort.dart';
import '../library/library_sort_sheet.dart';

/// Opens the filter create/edit sheet.
Future<void> showFilterEditor({
  required BuildContext context,
  required WidgetRef ref,
  MediaFilter? initialFilter,
  FilterDestination? editing,
}) {
  return showModalBottomSheet<void>(
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
    final selected = await showModalBottomSheet<LibrarySortSelection>(
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
      setState(() => _nameError = 'Name is required');
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
    final categories = MediaCategoryFilter.forKind(_filter.kind);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Material(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
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
                      color: AppColors.textSecondary.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Text(
                    widget.editing == null ? 'New filter' : 'Edit filter',
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
                      labelText: 'Name',
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
                    segments: const [
                      ButtonSegment(
                        value: MediaKind.movies,
                        label: Text('Movies'),
                      ),
                      ButtonSegment(
                        value: MediaKind.shows,
                        label: Text('TV Shows'),
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
                  child: DropdownButtonFormField<MediaCategoryFilter?>(
                    key: const Key('filter-editor-category'),
                    value: _filter.category,
                    decoration: const InputDecoration(labelText: 'Category'),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('All'),
                      ),
                      for (final category in categories)
                        DropdownMenuItem(
                          value: category,
                          child: Text(category.displayName),
                        ),
                    ],
                    onChanged: _setCategory,
                  ),
                ),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: SegmentedButton<WatchScope>(
                    segments: const [
                      ButtonSegment(
                        value: WatchScope.all,
                        label: Text('All'),
                      ),
                      ButtonSegment(
                        value: WatchScope.unwatched,
                        label: Text('Unwatched'),
                      ),
                      ButtonSegment(
                        value: WatchScope.favorites,
                        label: Text('Favorites'),
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
                  title: const Text('Sort'),
                  subtitle: Text(_filter.sort.field.displayName),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: _showSortPicker,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: FilledButton(
                    key: const Key('filter-editor-save'),
                    onPressed: _save,
                    child: const Text('Save'),
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
