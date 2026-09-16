/// The `SubtitleContent` request the player sends when a track is picked.
library;

import 'package:graphql_flutter/graphql_flutter.dart';

import '../../../graphql/queries/subtitle_content.graphql.dart';

/// Options for fetching one subtitle track's body.
///
/// An embedded track has no body until the server extracts it with ffmpeg,
/// which reads through the whole container: 7.5 s and 10.7 s for two 2.4 GB
/// 4K episodes. So this sets no `queryRequestTimeout` of its own and relies
/// on the client's, which is null. Over p2p the server stops waiting at 30 s
/// and answers with an error.
QueryOptions<Object?> subtitleContentQueryOptions({
  required String mediaFileId,
  required String trackId,
}) =>
    QueryOptions(
      document: documentNodeQuerySubtitleContent,
      variables: Variables$Query$SubtitleContent(
        mediaFileId: mediaFileId,
        trackId: trackId,
      ).toJson(),
    );
