/// Plex `MediaContainer` JSON to neutral models. Pure functions; every
/// field Plex may omit is treated as optional.
library;

import '../../../domain/sources/hub.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../source.dart';

const plexSortOptions = [
  SortOption(id: 'titleSort', label: 'Title'),
  SortOption(id: 'addedAt', label: 'Recently added', descendingByDefault: true),
  SortOption(
      id: 'originallyAvailableAt',
      label: 'Release date',
      descendingByDefault: true),
  SortOption(id: 'audienceRating', label: 'Rating', descendingByDefault: true),
  SortOption(
      id: 'lastViewedAt', label: 'Last watched', descendingByDefault: true),
];

const plexFilterOptions = [FilterOption(id: 'unwatched', label: 'Unwatched')];

ItemKind? plexItemKind(String? type) => switch (type) {
      'movie' => ItemKind.movie,
      'show' => ItemKind.show,
      'season' => ItemKind.season,
      'episode' => ItemKind.episode,
      'clip' => ItemKind.video,
      _ => null,
    };

Library? plexLibrary(SourceId sourceId, Map<String, dynamic> d) {
  final key = d['key'];
  if (key is! String) return null;
  final kind = switch (d['type']) {
    'movie' => '${d['agent']}'.contains('none')
        ? LibraryKind.videos
        : LibraryKind.movies,
    'show' => LibraryKind.shows,
    _ => null,
  };
  if (kind == null) return null;
  return Library(
    ref: LibraryRef(sourceId: sourceId, id: key),
    title: d['title'] as String? ?? 'Library',
    kind: kind,
    sortOptions: plexSortOptions,
    filterOptions: plexFilterOptions,
  );
}

int? _seconds(Object? ms) => ms is num ? (ms / 1000).round() : null;

ArtworkRef? _art(Object? path) =>
    path is String && path.isNotEmpty ? ArtworkRef(path) : null;

String? _firstPartId(Map<String, dynamic> m) {
  final media = m['Media'];
  if (media is! List || media.isEmpty || media.first is! Map) return null;
  final parts = (media.first as Map)['Part'];
  if (parts is! List || parts.isEmpty || parts.first is! Map) return null;
  final id = (parts.first as Map)['id'];
  return id == null ? null : '$id';
}

/// A Plex person's `thumb` is an absolute metadata-static URL, not a server
/// path. `artwork()` hands it to `/photo/:/transcode?url=`, which accepts
/// remote URLs, so it needs no special case.
List<Person> _roles(Object? list) => [
      for (final r in (list is List ? list : const []))
        if (r is Map && r['tag'] is String)
          Person(
            name: r['tag'] as String,
            role: r['role'] as String?,
            photo: _art(r['thumb']),
          ),
    ];

ItemRef? _parentRef(SourceId sourceId, ItemKind kind, Object? key) =>
    key is String
        ? ItemRef(sourceId: sourceId, kind: kind, externalId: key)
        : null;

ItemSummary? plexSummary(SourceId sourceId, Map<String, dynamic> m) {
  final kind = plexItemKind(m['type'] as String?);
  final id = m['ratingKey'];
  if (kind == null || id is! String) return null;
  final leafCount = m['leafCount'] as int?;
  final viewed = m['viewedLeafCount'] as int?;
  final watched = switch (kind) {
    ItemKind.show ||
    ItemKind.season =>
      leafCount != null && leafCount > 0 && (viewed ?? 0) >= leafCount,
    _ => ((m['viewCount'] as int?) ?? 0) > 0,
  };
  final index = m['index'] as int?;
  final parentIndex = m['parentIndex'] as int?;
  final episode = kind == ItemKind.episode;
  return ItemSummary(
    ref: ItemRef(sourceId: sourceId, kind: kind, externalId: id),
    title: m['title'] as String? ?? '',
    subtitle: episode && index != null && parentIndex != null
        ? 'S$parentIndex · E$index'
        : null,
    showTitle: episode ? m['grandparentTitle'] as String? : null,
    year: m['year'] as int?,
    // An episode's own thumb is a landscape still: the show's poster suits a
    // poster frame, and the still suits a backdrop.
    poster: _art(episode ? m['grandparentThumb'] ?? m['thumb'] : m['thumb']),
    backdrop: _art(episode ? m['thumb'] ?? m['art'] : m['art']),
    durationSeconds: _seconds(m['duration']),
    userState: UserState(
      watched: watched,
      progressSeconds: _seconds(m['viewOffset']),
    ),
    childCount: m['childCount'] as int? ?? leafCount,
    index: index,
    parentIndex: parentIndex,
    overview: m['summary'] as String?,
    airDate: m['originallyAvailableAt'] as String?,
    defaultVersionId: _firstPartId(m),
  );
}

/// Plex's own Continue Watching and On Deck hubs. The Continue Watching row
/// already shows them.
const plexContinueHubIds = {'home.continue', 'home.ondeck'};

/// A home hub, or null when it is one of [plexContinueHubIds] or holds
/// nothing this app plays. [libraryIds] are the sections a hub may link to;
/// Plex hubs carry no section id of their own, so it comes from the items.
Hub? plexHub(
  SourceId sourceId,
  Map<String, dynamic> h, {
  required Set<String> libraryIds,
}) {
  final hubId = h['hubIdentifier'];
  if (hubId is! String || plexContinueHubIds.contains(hubId)) return null;
  final metadata = [
    for (final m in (h['Metadata'] as List? ?? const []))
      if (m is Map) m.cast<String, dynamic>(),
  ];
  final items =
      metadata.map((m) => plexSummary(sourceId, m)).whereType<ItemSummary>();
  if (items.isEmpty) return null;
  final sections = {for (final m in metadata) '${m['librarySectionID']}'};
  final section = sections.length == 1 ? sections.single : null;
  return Hub(
    id: hubId,
    title: h['title'] as String? ?? '',
    items: items.toList(),
    library: section != null && libraryIds.contains(section)
        ? LibraryRef(sourceId: sourceId, id: section)
        : null,
  );
}

List<String> _tags(Object? list) => [
      for (final t in (list is List ? list : const []))
        if (t is Map && t['tag'] is String) t['tag'] as String,
    ];

MediaVersion? plexVersion(Map<String, dynamic> media) {
  final parts = media['Part'];
  if (parts is! List || parts.isEmpty) return null;
  final part = (parts.first as Map).cast<String, dynamic>();
  final partId = part['id'];
  if (partId == null) return null;
  return MediaVersion(
    id: '$partId',
    container: (part['container'] ?? media['container']) as String?,
    videoCodec: media['videoCodec'] as String?,
    audioCodec: media['audioCodec'] as String?,
    height: media['height'] as int?,
    bitrateKbps: media['bitrate'] as int?,
    durationSeconds: _seconds(part['duration'] ?? media['duration']),
    streamPath: part['key'] as String?,
    streams: [
      for (final s
          in (part['Stream'] is List ? part['Stream'] as List : const []))
        if (s is Map && (s['streamType'] == 2 || s['streamType'] == 3))
          MediaStreamInfo(
            id: '${s['id']}',
            kind: s['streamType'] == 2
                ? MediaStreamKind.audio
                : MediaStreamKind.subtitle,
            codec: s['codec'] as String?,
            language: s['languageCode'] as String?,
            title: s['displayTitle'] as String?,
            isDefault: s['selected'] == true || s['default'] == true,
            externalPath: s['key'] as String?,
          ),
    ],
  );
}

ItemDetail plexDetail(SourceId sourceId, Map<String, dynamic> m) {
  final summary = plexSummary(sourceId, m);
  if (summary == null) {
    throw ArgumentError('not a playable Plex item: ${m['type']}');
  }
  final rating = (m['audienceRating'] ?? m['rating']) as num?;
  return ItemDetail(
    summary: summary,
    overview: m['summary'] as String?,
    genres: _tags(m['Genre']),
    people: [..._tags(m['Role']), ..._tags(m['Director'])],
    studio: m['studio'] as String?,
    cast: _roles(m['Role']),
    contentRating: m['contentRating'] as String?,
    show: switch (summary.ref.kind) {
      ItemKind.episode =>
        _parentRef(sourceId, ItemKind.show, m['grandparentRatingKey']),
      ItemKind.season =>
        _parentRef(sourceId, ItemKind.show, m['parentRatingKey']),
      _ => null,
    },
    season: summary.ref.kind == ItemKind.episode
        ? _parentRef(sourceId, ItemKind.season, m['parentRatingKey'])
        : null,
    rating: rating?.toDouble(),
    versions: [
      for (final media in (m['Media'] is List ? m['Media'] as List : const []))
        if (media is Map) plexVersion(media.cast<String, dynamic>()),
    ].whereType<MediaVersion>().toList(),
  );
}
