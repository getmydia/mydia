/// Plex `MediaContainer` JSON to neutral models. Pure functions; every
/// field Plex may omit is treated as optional.
library;

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
  return ItemSummary(
    ref: ItemRef(sourceId: sourceId, kind: kind, externalId: id),
    title: m['title'] as String? ?? '',
    subtitle: kind == ItemKind.episode && index != null && parentIndex != null
        ? 'S$parentIndex · E$index'
        : null,
    year: m['year'] as int?,
    poster: _art(m['thumb']),
    backdrop: _art(m['art']),
    durationSeconds: _seconds(m['duration']),
    userState: UserState(
      watched: watched,
      progressSeconds: _seconds(m['viewOffset']),
    ),
    childCount: m['childCount'] as int? ?? leafCount,
    index: index,
    parentIndex: parentIndex,
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
    rating: rating?.toDouble(),
    versions: [
      for (final media in (m['Media'] is List ? m['Media'] as List : const []))
        if (media is Map) plexVersion(media.cast<String, dynamic>()),
    ].whereType<MediaVersion>().toList(),
  );
}
