import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/library/library_sort.dart';

void main() {
  test('wire names match the GraphQL enum values', () {
    expect(SortField.title.wireName, 'TITLE');
    expect(SortField.addedAt.wireName, 'ADDED_AT');
    expect(SortField.contentRating.wireName, 'CONTENT_RATING');
    expect(SortField.releaseDate.wireName, 'RELEASE_DATE');
    expect(SortField.lastPlayed.wireName, 'LAST_PLAYED');
    expect(SortField.watchState.wireName, 'WATCH_STATE');
    expect(SortField.random.wireName, 'RANDOM');
    expect(SortDirection.asc.wireName, 'ASC');
    expect(SortDirection.desc.wireName, 'DESC');
  });

  test('exposes eleven fields', () {
    expect(SortField.values.length, 11);
  });

  test('every field has a display name and none uses an em dash', () {
    for (final field in SortField.values) {
      expect(field.displayName, isNotEmpty);
      expect(field.displayName.contains('—'), isFalse);
    }
  });

  test('random is the only direction-less field', () {
    expect(SortField.random.supportsDirection, isFalse);
    for (final field in SortField.values.where((f) => f != SortField.random)) {
      expect(field.supportsDirection, isTrue);
    }
  });

  test('toVariables carries field and direction', () {
    const sort = LibrarySort(
      field: SortField.rating,
      direction: SortDirection.desc,
    );

    expect(sort.toVariables(), {'field': 'RATING', 'direction': 'DESC'});
  });

  test('toVariables carries the seed and omits direction for random', () {
    const sort = LibrarySort(
      field: SortField.random,
      direction: SortDirection.asc,
      randomSeed: 4242,
    );

    expect(sort.toVariables(), {'field': 'RANDOM', 'seed': 4242});
  });

  test('encode and decode round-trip field and direction', () {
    const sort = LibrarySort(
      field: SortField.lastPlayed,
      direction: SortDirection.asc,
    );

    expect(LibrarySort.decode(sort.encode()), sort);
  });

  test('decode falls back to the default for null or malformed input', () {
    expect(LibrarySort.decode(null), LibrarySort.defaultSort);
    expect(LibrarySort.decode(''), LibrarySort.defaultSort);
    expect(LibrarySort.decode('garbage'), LibrarySort.defaultSort);
    expect(LibrarySort.decode('NOT_A_FIELD:ASC'), LibrarySort.defaultSort);
  });

  test('the default is date added, descending', () {
    expect(LibrarySort.defaultSort.field, SortField.addedAt);
    expect(LibrarySort.defaultSort.direction, SortDirection.desc);
  });

  test('the seed is not part of equality, so it never busts persistence', () {
    const a = LibrarySort(field: SortField.title, direction: SortDirection.asc);
    const b = LibrarySort(
      field: SortField.title,
      direction: SortDirection.asc,
      randomSeed: 9,
    );

    expect(a, b);
  });
}
