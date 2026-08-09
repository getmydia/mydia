/// Library ordering, mirroring the server's `SortField` and `SortDirection`
/// GraphQL enums.
///
/// Field and direction are separate rather than baked into one option per
/// combination, which is how Plex and Jellyfin both present sorting and what
/// keeps the sheet at eleven rows instead of twenty-one.
enum SortField {
  title('TITLE', 'Title'),
  year('YEAR', 'Year'),
  addedAt('ADDED_AT', 'Date Added'),
  rating('RATING', 'Rating'),
  runtime('RUNTIME', 'Duration'),
  popularity('POPULARITY', 'Popularity'),
  contentRating('CONTENT_RATING', 'Content Rating'),
  releaseDate('RELEASE_DATE', 'Release Date'),
  lastPlayed('LAST_PLAYED', 'Last Played'),
  watchState('WATCH_STATE', 'Watch State'),
  random('RANDOM', 'Random');

  const SortField(this.wireName, this.displayName);

  /// The GraphQL enum value.
  final String wireName;

  /// The label shown in the sort sheet.
  final String displayName;

  /// Random ignores direction: one shuffle has no ascending form.
  bool get supportsDirection => this != SortField.random;

  static SortField? fromWireName(String name) {
    for (final field in SortField.values) {
      if (field.wireName == name) return field;
    }
    return null;
  }
}

enum SortDirection {
  asc('ASC'),
  desc('DESC');

  const SortDirection(this.wireName);

  final String wireName;

  SortDirection get flipped =>
      this == SortDirection.asc ? SortDirection.desc : SortDirection.asc;

  static SortDirection? fromWireName(String name) {
    for (final direction in SortDirection.values) {
      if (direction.wireName == name) return direction;
    }
    return null;
  }
}

/// A chosen ordering, ready to send as the `sort` GraphQL variable.
///
/// [randomSeed] is session state rather than a preference, so it is excluded
/// from [encode]: persisting it would freeze one permutation forever, which is
/// the opposite of what picking Random means.
///
/// It is part of equality, though, and deliberately so. This type is a Riverpod
/// family argument, so equality decides whether re-selecting Random gets a new
/// watcher. Excluding the seed would make two shuffles compare equal and the
/// reshuffle would silently do nothing.
class LibrarySort {
  const LibrarySort({
    required this.field,
    required this.direction,
    this.randomSeed,
  });

  final SortField field;
  final SortDirection direction;
  final int? randomSeed;

  static const LibrarySort defaultSort = LibrarySort(
    field: SortField.addedAt,
    direction: SortDirection.desc,
  );

  LibrarySort copyWith({
    SortField? field,
    SortDirection? direction,
    int? randomSeed,
  }) {
    return LibrarySort(
      field: field ?? this.field,
      direction: direction ?? this.direction,
      randomSeed: randomSeed ?? this.randomSeed,
    );
  }

  Map<String, dynamic> toVariables() {
    if (field == SortField.random) {
      return {
        'field': field.wireName,
        if (randomSeed != null) 'seed': randomSeed,
      };
    }
    return {'field': field.wireName, 'direction': direction.wireName};
  }

  String encode() => '${field.wireName}:${direction.wireName}';

  static LibrarySort decode(String? raw) {
    if (raw == null || raw.isEmpty) return defaultSort;

    final parts = raw.split(':');
    if (parts.length != 2) return defaultSort;

    final field = SortField.fromWireName(parts[0]);
    final direction = SortDirection.fromWireName(parts[1]);
    if (field == null || direction == null) return defaultSort;

    return LibrarySort(field: field, direction: direction);
  }

  @override
  bool operator ==(Object other) =>
      other is LibrarySort &&
      other.field == field &&
      other.direction == direction &&
      other.randomSeed == randomSeed;

  @override
  int get hashCode => Object.hash(field, direction, randomSeed);

  @override
  String toString() =>
      'LibrarySort(${field.wireName}, ${direction.wireName}, seed: $randomSeed)';
}
