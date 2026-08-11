import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';

import '../../../core/graphql/graphql_provider.dart';
import '../../../core/graphql/watch/schema_downgrade.dart';
import '../../../domain/models/media_stream.dart';
import '../../../domain/models/subtitle_track.dart';
import '../../../graphql/queries/media_info.graphql.dart';
import 'media_info_sheet.dart';

typedef MediaInfoArgs = ({String id, MediaInfoTarget target});

/// Fetches the files and per-stream detail for one movie or episode.
///
/// A new player can meet an older self-hosted server that does not define the
/// stream fields, so a rejected query retries once with the legacy document.
/// The panel then shows the same "not captured yet" state it shows for a file
/// the server-side backfill has not reached.
final mediaInfoProvider =
    FutureProvider.family<List<MediaFileInfo>, MediaInfoArgs>(
        (ref, args) async {
  final client = ref.watch(graphqlClientProvider);
  if (client == null) {
    throw Exception('GraphQL client not available');
  }

  final document = args.target == MediaInfoTarget.movie
      ? documentNodeQueryMovieMediaInfo
      : documentNodeQueryEpisodeMediaInfo;

  final fallback = args.target == MediaInfoTarget.movie
      ? documentNodeQueryMovieMediaInfoLegacy
      : documentNodeQueryEpisodeMediaInfoLegacy;

  Future<QueryResult<Object?>> run(doc) {
    return client.query(
      QueryOptions(
        document: doc,
        variables: {'id': args.id},
        fetchPolicy: FetchPolicy.networkOnly,
      ),
    );
  }

  var result = await run(document);

  // Only an unknown-field rejection means the server predates these fields.
  // Retrying on any exception would mask a network, auth or server error by
  // re-running the narrower query and returning partial data as if it were
  // whole. Same gate QueryWatcher uses for its own schema downgrade.
  if (result.hasException && isUnknownFieldError(result.exception!)) {
    result = await run(fallback);
  }
  if (result.hasException) {
    throw result.exception!;
  }

  final root = args.target == MediaInfoTarget.movie ? 'movie' : 'episode';
  final data = result.data?[root] as Map<String, dynamic>?;
  final files = (data?['files'] as List<dynamic>? ?? const []);

  return files
      .cast<Map<String, dynamic>>()
      .map(mediaFileInfoFromJson)
      .toList(growable: false);
});

/// Maps one `MediaInfoFragment` payload onto [MediaFileInfo].
///
/// Public only so it can be unit tested without a GraphQL client.
@visibleForTesting
MediaFileInfo mediaFileInfoFromJson(Map<String, dynamic> json) {
  final streams = json['streams'] as List<dynamic>?;
  final external = json['externalSubtitles'] as List<dynamic>?;

  return MediaFileInfo(
    id: json['id'].toString(),
    fileName: json['fileName'] as String?,
    directory: json['directory'] as String?,
    container: json['container'] as String?,
    durationSeconds: (json['duration'] as num?)?.toDouble(),
    sizeBytes: json['size'] as int?,
    bitrate: json['bitrate'] as int?,
    resolution: json['resolution'] as String?,
    codec: json['codec'] as String?,
    streams:
        streams?.cast<Map<String, dynamic>>().map(_streamFromJson).toList(),
    externalSubtitles: (external ?? const [])
        .cast<Map<String, dynamic>>()
        .map(_externalSubtitleFromJson)
        .toList(growable: false),
  );
}

SubtitleTrack _externalSubtitleFromJson(Map<String, dynamic> json) {
  return SubtitleTrack(
    id: json['trackId'].toString(),
    language: json['language'] as String? ?? 'und',
    title: json['title'] as String?,
    format: json['format'] as String? ?? 'srt',
    embedded: json['embedded'] as bool? ?? false,
  );
}

MediaStream _streamFromJson(Map<String, dynamic> json) {
  return MediaStream(
    index: json['index'] as int?,
    type: _typeFromName(json['type'] as String?),
    codec: json['codec'] as String?,
    codecLong: json['codecLong'] as String?,
    profile: json['profile'] as String?,
    level: json['level'] as int?,
    language: json['language'] as String?,
    title: json['title'] as String?,
    bitrate: json['bitrate'] as int?,
    isDefault: json['isDefault'] as bool? ?? false,
    isForced: json['isForced'] as bool? ?? false,
    isHearingImpaired: json['isHearingImpaired'] as bool? ?? false,
    isCommentary: json['isCommentary'] as bool? ?? false,
    width: json['width'] as int?,
    height: json['height'] as int?,
    frameRate: (json['frameRate'] as num?)?.toDouble(),
    pixelFormat: json['pixelFormat'] as String?,
    bitDepth: json['bitDepth'] as int?,
    colorSpace: json['colorSpace'] as String?,
    colorTransfer: json['colorTransfer'] as String?,
    colorPrimaries: json['colorPrimaries'] as String?,
    dolbyVisionProfile: json['dolbyVisionProfile'] as int?,
    aspectRatio: json['aspectRatio'] as String?,
    channels: json['channels'] as int?,
    channelLayout: json['channelLayout'] as String?,
    sampleRate: json['sampleRate'] as int?,
  );
}

MediaStreamType _typeFromName(String? name) {
  switch (name?.toUpperCase()) {
    case 'AUDIO':
      return MediaStreamType.audio;
    case 'SUBTITLE':
      return MediaStreamType.subtitle;
    default:
      return MediaStreamType.video;
  }
}
