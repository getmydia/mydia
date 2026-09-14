/// The `SubtitleContent` request the player sends when a track is picked.
library;

import 'package:graphql_flutter/graphql_flutter.dart';

import '../../../graphql/queries/subtitle_content.graphql.dart';

/// How long a subtitle body may take to arrive.
///
/// An embedded track has no body until the server extracts it with ffmpeg,
/// which reads through the whole container: 7.5 s and 10.7 s for two 2.4 GB
/// 4K episodes. graphql's own default gives up after 5 s, so every such pick
/// failed while the server went on to finish and cache the body. Over p2p the
/// transport ends its own wait at 30 s with an error, so this never outlasts
/// the server there.
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
      queryRequestTimeout: kSubtitleContentTimeout,
    );
