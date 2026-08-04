import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/home_data.dart';

part 'home_controller.g.dart';

const String homeScreenQuery = r'''
query HomeScreen($continueWatchingLimit: Int, $recentlyAddedLimit: Int, $upNextLimit: Int, $favoritesLimit: Int) {
  continueWatching(first: $continueWatchingLimit) {
    id
    type
    title
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    progress {
      positionSeconds
      durationSeconds
      percentage
      watched
      lastWatchedAt
    }
    showId
    showTitle
    seasonNumber
    episodeNumber
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
    }
  }

  recentlyAdded(first: $recentlyAddedLimit) {
    id
    type
    title
    year
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    addedAt
  }

  upNext(first: $upNextLimit) {
    progressState
    episode {
      id
      seasonNumber
      episodeNumber
      title
      airDate
      thumbnailUrl
      hasFile
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
      }
      progress {
        positionSeconds
        durationSeconds
        percentage
        watched
        lastWatchedAt
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

  favorites(first: $favoritesLimit) {
    id
    type
    title
    year
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    addedAt
  }
}
''';

const Map<String, dynamic> homeScreenVariables = {
  'continueWatchingLimit': 10,
  'recentlyAddedLimit': 20,
  'upNextLimit': 10,
  'favoritesLimit': 10,
};

@riverpod
class HomeController extends _$HomeController {
  // Plain `late`, not `late final`: Riverpod may re-run build() on the same
  // notifier instance, and a second assignment to a late final throws.
  late QueryWatcher<HomeData> _watcher;

  @override
  Stream<HomeData> build() {
    _watcher = createWatcher<HomeData>(
      ref,
      key: QueryKeys.home,
      document: gql(homeScreenQuery),
      variables: homeScreenVariables,
      parse: HomeData.fromJson,
    );
    return _watcher.stream;
  }

  Future<void> refresh() => _watcher.refetch();
}
