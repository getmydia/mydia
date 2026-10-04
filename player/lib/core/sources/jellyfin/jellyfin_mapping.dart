/// Jellyfin `BaseItemDto` JSON to neutral models.
library;

import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../source.dart';

const jellyfinTicksPerSecond = 10000000;

int? jellyfinSeconds(Object? ticks) =>
    ticks is num ? (ticks / jellyfinTicksPerSecond).round() : null;

/// Null for a library the player does not show (music, books, photos,
/// Live TV, playlists, collections).
LibraryKind? jellyfinLibraryKind(String? collectionType) =>
    switch (collectionType) {
      'movies' => LibraryKind.movies,
      'tvshows' => LibraryKind.shows,
      null || 'homevideos' || 'musicvideos' || 'mixed' => LibraryKind.videos,
      _ => null,
    };

ItemKind? jellyfinItemKind(String? type) => switch (type) {
      'Movie' => ItemKind.movie,
      'Series' => ItemKind.show,
      'Season' => ItemKind.season,
      'Episode' => ItemKind.episode,
      'Video' || 'MusicVideo' => ItemKind.video,
      'Folder' || 'CollectionFolder' => ItemKind.folder,
      _ => null,
    };

const jellyfinSortOptions = [
  SortOption(id: 'SortName', label: 'Title', shared: SharedSort.title),
  SortOption(
      id: 'DateCreated',
      label: 'Recently added',
      descendingByDefault: true,
      shared: SharedSort.added),
  SortOption(
      id: 'PremiereDate',
      label: 'Release date',
      descendingByDefault: true,
      shared: SharedSort.released),
  SortOption(id: 'CommunityRating', label: 'Rating', descendingByDefault: true),
];

const jellyfinFilterOptions = [
  FilterOption(id: 'IsUnplayed', label: 'Unwatched'),
  FilterOption(id: 'IsResumable', label: 'In progress'),
];

/// The `Fields` a merged grid or row needs on top of the defaults.
const jellyfinSortFields = 'SortName,DateCreated';

/// `IncludeItemTypes` for browsing a library of [kind].
String jellyfinItemTypes(LibraryKind kind) => switch (kind) {
      LibraryKind.movies => 'Movie',
      LibraryKind.shows => 'Series',
      LibraryKind.videos => 'Video,Movie,Episode,MusicVideo',
    };

/// The format the player asks Jellyfin to convert a sidecar to.
String jellyfinSubtitleExtension(String? codec) =>
    switch (codec?.toLowerCase()) {
      'webvtt' || 'vtt' => 'vtt',
      'ass' => 'ass',
      'ssa' => 'ssa',
      _ => 'srt',
    };

Library? jellyfinLibrary(SourceId sourceId, Map<String, dynamic> json) {
  final id = json['Id'] as String?;
  final kind = jellyfinLibraryKind(json['CollectionType'] as String?);
  if (id == null || kind == null) return null;
  return Library(
    ref: LibraryRef(sourceId: sourceId, id: id),
    title: json['Name'] as String? ?? 'Library',
    kind: kind,
    sortOptions: jellyfinSortOptions,
    filterOptions: jellyfinFilterOptions,
  );
}

ItemSummary? jellyfinSummary(SourceId sourceId, Map<String, dynamic> json) {
  final id = json['Id'] as String?;
  final kind = jellyfinItemKind(json['Type'] as String?);
  if (id == null || kind == null) return null;
  final tags = (json['ImageTags'] as Map?)?.cast<String, dynamic>() ?? const {};
  final backdrops = json['BackdropImageTags'] as List? ?? const [];
  ArtworkRef? image(String type, Object? tag) =>
      tag is String ? ArtworkRef('/Items/$id/Images/$type?tag=$tag') : null;
  final user = (json['UserData'] as Map?)?.cast<String, dynamic>() ?? const {};
  final position = jellyfinSeconds(user['PlaybackPositionTicks']);
  final episode = kind == ItemKind.episode;
  final index = json['IndexNumber'] as int?;
  final parentIndex = episode ? json['ParentIndexNumber'] as int? : null;
  // An episode's own Primary image is a landscape still: the series poster
  // suits a poster frame, and the still suits a backdrop. Plex does the same.
  final seriesId = json['SeriesId'];
  final seriesTag = json['SeriesPrimaryImageTag'];
  final seriesPoster = episode && seriesId is String && seriesTag is String
      ? ArtworkRef('/Items/$seriesId/Images/Primary?tag=$seriesTag')
      : null;
  return ItemSummary(
    ref: ItemRef(sourceId: sourceId, kind: kind, externalId: id),
    title: json['Name'] as String? ?? 'Untitled',
    subtitle: episode && index != null && parentIndex != null
        ? 'S$parentIndex · E$index'
        : null,
    showTitle: episode ? json['SeriesName'] as String? : null,
    year: json['ProductionYear'] as int?,
    poster: seriesPoster ??
        image('Primary', tags['Primary']) ??
        image('Thumb', tags['Thumb']),
    backdrop: (episode ? image('Primary', tags['Primary']) : null) ??
        image('Backdrop', backdrops.firstOrNull) ??
        image('Thumb', tags['Thumb']),
    durationSeconds: jellyfinSeconds(json['RunTimeTicks']),
    userState: UserState(
      watched: user['Played'] == true,
      progressSeconds: position == 0 ? null : position,
    ),
    childCount: json['ChildCount'] as int?,
    index: index,
    parentIndex: parentIndex,
    overview: json['Overview'] as String?,
    airDate: _isoDate(json['PremiereDate']),
    // An item's own id is the id of its primary media source.
    defaultVersionId: id,
    sortTitle: json['SortName'] as String?,
    // A show or season's newest episode arrival, when the response carries it.
    addedAt:
        _instant(json['DateLastMediaAdded']) ?? _instant(json['DateCreated']),
    lastPlayedAt: _instant(user['LastPlayedDate']),
  );
}

DateTime? _instant(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

/// The `yyyy-MM-dd` head of an ISO timestamp; shorter strings pass as is.
String? _isoDate(Object? value) => value is String && value.isNotEmpty
    ? value.substring(0, value.length < 10 ? value.length : 10)
    : null;

ItemRef? _jref(SourceId sourceId, ItemKind kind, Object? id) => id is String
    ? ItemRef(sourceId: sourceId, kind: kind, externalId: id)
    : null;

List<Person> _actors(Object? list) => [
      for (final p in (list is List ? list : const []))
        if (p is Map && p['Type'] == 'Actor' && p['Name'] is String)
          Person(
            name: p['Name'] as String,
            role: p['Role'] as String?,
            photo: p['Id'] is String && p['PrimaryImageTag'] is String
                ? ArtworkRef(
                    '/Items/${p['Id']}/Images/Primary?tag=${p['PrimaryImageTag']}')
                : null,
          ),
    ];

String? _trailerUrl(Object? trailers) {
  if (trailers is! List || trailers.isEmpty) return null;
  final first = trailers.first;
  return first is Map && first['Url'] is String ? first['Url'] as String : null;
}

List<String> _names(Object? list) => [
      for (final p in (list is List ? list : const []))
        if (p is Map && p['Name'] is String) p['Name'] as String,
    ];

MediaStreamInfo? _stream(
    String itemId, String sourceId, Map<String, dynamic> s) {
  final kind = switch (s['Type']) {
    'Audio' => MediaStreamKind.audio,
    'Subtitle' => MediaStreamKind.subtitle,
    _ => null,
  };
  final index = s['Index'];
  if (kind == null || index is! int) return null;
  final external = kind == MediaStreamKind.subtitle && s['IsExternal'] == true;
  final ext = jellyfinSubtitleExtension(s['Codec'] as String?);
  return MediaStreamInfo(
    id: '$index',
    kind: kind,
    // A sidecar is fetched converted to [ext], so that is its format.
    codec: external ? ext : s['Codec'] as String?,
    language: s['Language'] as String?,
    title: s['DisplayTitle'] as String?,
    isDefault: s['IsDefault'] == true,
    externalPath: external
        ? '/Videos/$itemId/$sourceId/Subtitles/$index/Stream.$ext'
        : null,
  );
}

MediaVersion? _version(String itemId, Map<String, dynamic> source) {
  final id = source['Id'] as String?;
  if (id == null) return null;
  final streams = [
    for (final s in (source['MediaStreams'] as List? ?? const []))
      if (s is Map) s.cast<String, dynamic>(),
  ];
  final video = streams.where((s) => s['Type'] == 'Video').firstOrNull;
  final audio = streams.where((s) => s['Type'] == 'Audio').firstOrNull;
  final bitrate = source['Bitrate'] as num?;
  return MediaVersion(
    id: id,
    container: (source['Container'] as String?)?.split(',').first,
    videoCodec: video?['Codec'] as String?,
    audioCodec: audio?['Codec'] as String?,
    height: video?['Height'] as int?,
    bitrateKbps: bitrate == null ? null : (bitrate / 1000).round(),
    durationSeconds: jellyfinSeconds(source['RunTimeTicks']),
    streamPath: '/Videos/$itemId/stream?static=true&mediaSourceId=$id',
    streams: [
      for (final s in streams)
        if (_stream(itemId, id, s) case final info?) info,
    ],
  );
}

ItemDetail? jellyfinDetail(SourceId sourceId, Map<String, dynamic> json) {
  final summary = jellyfinSummary(sourceId, json);
  if (summary == null) return null;
  final itemId = summary.ref.externalId;
  final studios = _names(json['Studios']);
  final kind = summary.ref.kind;
  final user = (json['UserData'] as Map?) ?? const {};
  return ItemDetail(
    summary: summary,
    overview: json['Overview'] as String?,
    genres: [
      for (final g in (json['Genres'] as List? ?? const []))
        if (g is String) g,
    ],
    people: _names(json['People']),
    studio: studios.firstOrNull,
    tags: [
      for (final t in (json['Tags'] as List? ?? const []))
        if (t is String) t,
    ],
    rating: (json['CommunityRating'] as num?)?.toDouble(),
    cast: _actors(json['People']),
    trailerUrl: _trailerUrl(json['RemoteTrailers']),
    contentRating: json['OfficialRating'] as String?,
    isFavorite: user['IsFavorite'] == true,
    show: kind == ItemKind.episode || kind == ItemKind.season
        ? _jref(sourceId, ItemKind.show, json['SeriesId'])
        : null,
    season: kind == ItemKind.episode
        ? _jref(sourceId, ItemKind.season, json['SeasonId'])
        : null,
    versions: [
      for (final s in (json['MediaSources'] as List? ?? const []))
        if (s is Map)
          if (_version(itemId, s.cast<String, dynamic>()) case final v?) v,
    ],
  );
}
