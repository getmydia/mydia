import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/settings/settings_service.dart';
import 'library_controller.dart' show LibraryType;
import 'library_sort.dart';

part 'library_sort_provider.g.dart';

/// The chosen ordering for one library, loaded from storage before the
/// library query runs.
///
/// The library screen waits on this rather than mounting under the default
/// and correcting afterwards, which would fire two queries and show a flash
/// of the wrong order.
@riverpod
class LibrarySortController extends _$LibrarySortController {
  static const _movieSeedBase = 0x5EED;

  String get _storageKey =>
      libraryType == LibraryType.movies ? 'movies' : 'tvShows';

  @override
  Future<LibrarySort> build(LibraryType libraryType) async {
    final raw = await SettingsService().getLibrarySort(_storageKey);
    final stored = LibrarySort.decode(raw);

    // A persisted `random` needs a fresh permutation each launch, so the seed
    // is minted here rather than restored.
    return stored.field == SortField.random
        ? stored.copyWith(randomSeed: _mintSeed())
        : stored;
  }

  /// Selects [field]. Re-selecting the current field flips direction, which is
  /// how Plex behaves. Re-selecting random reshuffles.
  Future<void> select(SortField field) async {
    final current = state.value ?? LibrarySort.defaultSort;

    final next = switch (field) {
      SortField.random => LibrarySort(
          field: SortField.random,
          direction: current.direction,
          randomSeed: _mintSeed(),
        ),
      _ when field == current.field => current.copyWith(
          field: field,
          direction: current.direction.flipped,
        ),
      _ => LibrarySort(field: field, direction: current.direction),
    };

    state = AsyncData(next);
    await SettingsService().setLibrarySort(_storageKey, next.encode());
  }

  /// Flips direction without changing field. A no-op for random.
  Future<void> toggleDirection() async {
    final current = state.value ?? LibrarySort.defaultSort;
    if (!current.field.supportsDirection) return;

    final next = current.copyWith(direction: current.direction.flipped);
    state = AsyncData(next);
    await SettingsService().setLibrarySort(_storageKey, next.encode());
  }

  // DateTime rather than Random so the seed varies per selection without
  // pulling in another dependency. Collisions only mean a repeated shuffle.
  int _mintSeed() =>
      DateTime.now().microsecondsSinceEpoch.remainder(0x7FFFFFFF) ^
      _movieSeedBase;
}
