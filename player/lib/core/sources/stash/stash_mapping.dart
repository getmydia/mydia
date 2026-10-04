/// Stash scene JSON to neutral models.
library;

import '../../../domain/sources/item.dart';
import '../../../domain/sources/library.dart';
import '../source.dart';

/// Stash has no libraries; v1 presents every scene as one.
const stashScenesLibraryId = 'scenes';

const stashSortOptions = [
  SortOption(
      id: 'created_at',
      label: 'Recently added',
      descendingByDefault: true,
      shared: SharedSort.added),
  SortOption(id: 'title', label: 'Title', shared: SharedSort.title),
  SortOption(
      id: 'date',
      label: 'Date',
      descendingByDefault: true,
      shared: SharedSort.released),
  SortOption(id: 'rating', label: 'Rating', descendingByDefault: true),
  SortOption(id: 'play_count', label: 'Most played', descendingByDefault: true),
  SortOption(
      id: 'last_played_at', label: 'Last played', descendingByDefault: true),
  SortOption(id: 'random', label: 'Random'),
];

const stashFilterOptions = [FilterOption(id: 'unplayed', label: 'Unplayed')];

/// A server-made URL as a path relative to the server, without the
/// `apikey` parameter Stash adds when the request carried a key.
String? stashRelativePath(String? url) {
  if (url == null || url.isEmpty) return null;
  final uri = Uri.parse(url);
  final query = Map.of(uri.queryParameters)..remove('apikey');
  final rebuilt = Uri(
    path: uri.path,
    queryParameters: query.isEmpty ? null : query,
  );
  return rebuilt.toString();
}

Map<String, dynamic>? _firstFile(Map<String, dynamic> scene) {
  final files = scene['files'];
  return files is List && files.isNotEmpty && files.first is Map
      ? (files.first as Map).cast<String, dynamic>()
      : null;
}

DateTime? _instant(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

ItemSummary stashSummary(SourceId sourceId, Map<String, dynamic> scene) {
  final id = scene['id'] as String;
  final file = _firstFile(scene);
  final title = (scene['title'] as String?)?.trim();
  final date = scene['date'] as String?;
  final screenshot =
      stashRelativePath((scene['paths'] as Map?)?['screenshot'] as String?);
  return ItemSummary(
    ref: ItemRef(sourceId: sourceId, kind: ItemKind.video, externalId: id),
    title: title != null && title.isNotEmpty
        ? title
        : (file?['basename'] as String? ?? 'Scene $id'),
    subtitle: (scene['studio'] as Map?)?['name'] as String? ?? date,
    year: date != null && date.length >= 4
        ? int.tryParse(date.substring(0, 4))
        : null,
    poster: screenshot == null ? null : ArtworkRef(screenshot),
    backdrop: screenshot == null ? null : ArtworkRef(screenshot),
    durationSeconds: (file?['duration'] as num?)?.round(),
    userState: UserState(
      watched: ((scene['play_count'] as int?) ?? 0) > 0,
      progressSeconds: (scene['resume_time'] as num?)?.round(),
    ),
    addedAt: _instant(scene['created_at']),
    lastPlayedAt: _instant(scene['last_played_at']),
  );
}

List<String> _names(Object? list) => [
      for (final p in (list is List ? list : const []))
        if (p is Map && p['name'] is String) p['name'] as String,
    ];

ItemDetail stashDetail(SourceId sourceId, Map<String, dynamic> scene) {
  final summary = stashSummary(sourceId, scene);
  final id = summary.ref.externalId;
  final rating = scene['rating100'] as num?;
  final captions = [
    for (final c
        in (scene['captions'] is List ? scene['captions'] as List : const []))
      if (c is Map && c['language_code'] is String)
        MediaStreamInfo(
          id: '${c['language_code']}.${c['caption_type']}',
          kind: MediaStreamKind.subtitle,
          codec: c['caption_type'] as String?,
          language: c['language_code'] as String,
          title: '${c['language_code']}'.toUpperCase(),
          externalPath: '/scene/$id/caption?lang=${c['language_code']}'
              '&type=${c['caption_type']}',
        ),
  ];
  return ItemDetail(
    summary: summary,
    overview: scene['details'] as String?,
    people: _names(scene['performers']),
    studio: (scene['studio'] as Map?)?['name'] as String?,
    tags: _names(scene['tags']),
    rating: rating == null ? null : rating / 10,
    versions: [
      for (final f
          in (scene['files'] is List ? scene['files'] as List : const []))
        if (f is Map)
          MediaVersion(
            id: '${f['id']}',
            container: f['format'] as String?,
            videoCodec: f['video_codec'] as String?,
            audioCodec: f['audio_codec'] as String?,
            height: f['height'] as int?,
            bitrateKbps: f['bit_rate'] is num
                ? ((f['bit_rate'] as num) / 1000).round()
                : null,
            durationSeconds: (f['duration'] as num?)?.round(),
            streamPath: '/scene/$id/stream',
            streams: captions,
          ),
    ],
  );
}
