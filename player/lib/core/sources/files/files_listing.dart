/// Sorting, paging and matching text for files library listings.
library;

import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';

const filesSortOptions = [
  SortOption(id: 'title', name: SortName.title, shared: SharedSort.title),
  SortOption(
      id: 'added',
      name: SortName.recentlyAdded,
      descendingByDefault: true,
      shared: SharedSort.added),
  SortOption(
      id: 'released',
      name: SortName.releaseDate,
      descendingByDefault: true,
      shared: SharedSort.released),
];

const filesFilterOptions = [
  FilterOption(id: 'unwatched', name: FilterName.unwatched),
];

final _leadingArticle = RegExp(r'^(the|a|an)\s+', caseSensitive: false);

/// [title] without a leading English article, for sorting.
String filesSortTitle(String title) {
  final stripped = title.replaceFirst(_leadingArticle, '');
  return stripped.isEmpty ? title : stripped;
}

/// Seasons ascending, specials (season 0) last.
int compareSeasons(int a, int b) {
  if (a == b) return 0;
  if (a == 0) return 1;
  if (b == 0) return -1;
  return a.compareTo(b);
}

/// [items] in [sortId] order ([filesSortOptions]), [descending] when given.
List<ItemSummary> sortFilesItems(
  List<ItemSummary> items,
  String? sortId, {
  bool? descending,
}) {
  final sort = filesSortOptions.where((o) => o.id == sortId).firstOrNull ??
      filesSortOptions.first;
  final desc = descending ?? sort.descendingByDefault;
  int byTitle(ItemSummary a, ItemSummary b) => (a.sortTitle ?? a.title)
      .toLowerCase()
      .compareTo((b.sortTitle ?? b.title).toLowerCase());
  String released(ItemSummary i) => i.airDate ?? '${i.year ?? ''}';
  int compare(ItemSummary a, ItemSummary b) => switch (sort.id) {
        'added' =>
          (a.addedAt ?? DateTime(0)).compareTo(b.addedAt ?? DateTime(0)),
        'released' => released(a).compareTo(released(b)),
        _ => byTitle(a, b),
      };
  final sorted = [...items]..sort((a, b) {
      final c = desc ? compare(b, a) : compare(a, b);
      return c != 0 ? c : byTitle(a, b);
    });
  return sorted;
}

/// One page of [items] from the decimal offset in [cursor].
Page<ItemSummary> filesPage(
  List<ItemSummary> items,
  int pageSize, {
  Cursor? cursor,
}) {
  final start = (int.tryParse(cursor?.value ?? '') ?? 0).clamp(0, items.length);
  final end = (start + pageSize).clamp(0, items.length);
  return Page(
    items: items.sublist(start, end),
    total: items.length,
    nextCursor: end < items.length ? Cursor('$end') : null,
  );
}

/// The `identity_key` of the Rust name parser: lowercase, alphanumerics only.
String filesIdentityKey(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');
