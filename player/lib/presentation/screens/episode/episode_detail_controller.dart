import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/episode_detail.dart';

part 'episode_detail_controller.g.dart';

const String episodeDetailQuery = r'''
query EpisodeDetail($id: ID!) {
  episode(id: $id) {
    id
    seasonNumber
    episodeNumber
    title
    overview
    airDate
    runtime
    monitored
    thumbnailUrl
    hasFile
    progress {
      positionSeconds
      durationSeconds
      percentage
      watched
      lastWatchedAt
    }
    files {
      id
      resolution
      codec
      audioCodec
      hdrFormat
      size
      bitrate
      directPlaySupported
      streamUrl
      directPlayUrl
      subtitles {
        trackId
        language
        title
        format
        embedded
        url(format: VTT)
      }
    }
    show {
      id
      title
      artwork {
        posterUrl
        backdropUrl
        thumbnailUrl
      }
    }
  }
}
''';

EpisodeDetail _parseEpisode(Map<String, dynamic> data) {
  final episode = data['episode'];
  if (episode == null) throw Exception('Episode not found');
  return EpisodeDetail.fromJson(episode as Map<String, dynamic>);
}

@riverpod
class EpisodeDetailController extends _$EpisodeDetailController {
  late QueryWatcher<EpisodeDetail> _watcher;

  @override
  Stream<EpisodeDetail> build(String id) {
    _watcher = createWatcher<EpisodeDetail>(
      ref,
      key: QueryKeys.episodeDetail(id),
      document: gql(episodeDetailQuery),
      variables: {'id': id},
      parse: _parseEpisode,
    );
    return _watcher.stream;
  }

  Future<void> refresh() => _watcher.refetch();
}
