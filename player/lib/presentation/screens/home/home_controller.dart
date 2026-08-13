import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/home_data.dart';

part 'home_controller.g.dart';

const String homeScreenQuery = r'''
query HomeScreen($continueWatchingLimit: Int, $recentlyAddedLimit: Int, $favoritesLimit: Int) {
  continueWatching(first: $continueWatchingLimit) {
    id
    type
    title
    state
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
    newEpisodeCount
    latestSeasonNumber
    latestEpisodeNumber
    watchStatus { watched percentage unwatchedEpisodeCount }
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
    watchStatus { watched percentage unwatchedEpisodeCount }
  }
}
''';

/// The pre-episode-context shape, for a server older than this build.
const String homeScreenQueryLegacy = r'''
query HomeScreen($continueWatchingLimit: Int, $recentlyAddedLimit: Int, $favoritesLimit: Int) {
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
      fallbackDocument: gql(homeScreenQueryLegacy),
      variables: homeScreenVariables,
      parse: HomeData.fromJson,
    );
    return _watcher.stream;
  }

  Future<void> refresh() => _watcher.refetch();
}
