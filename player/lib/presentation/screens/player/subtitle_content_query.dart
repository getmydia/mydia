/// The `SubtitleContent` request the player sends when a track is picked.
library;

import 'package:graphql_flutter/graphql_flutter.dart';

import '../../../graphql/queries/subtitle_content.graphql.dart';

/// How long a subtitle body may take to arrive.
///
/// An embedded track has no body until the server extracts it with ffmpeg,
/// which reads through the whole container: 7.5 s and 10.7 s for two 2.4 GB
/// 4K episodes. graphql's original default gave up after 5 s, but [GraphQLClient]
/// now defaults to `queryRequestTimeout: null` so requests are bounded by
/// transport-level timeouts instead of graphql's default 5 s abort. Over p2p the
/// transport ends its own wait at 30 s with an error.
const kSubtitleContentTimeout = Duration(seconds: 60);

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
