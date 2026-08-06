import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/invalidation_rules.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../core/graphql/watch/watcher_registry.dart';
import '../../../domain/models/show_detail.dart';

part 'show_detail_controller.g.dart';

const String tvShowDetailQuery = r'''
query TvShowDetail($id: ID!) {
  tvShow(id: $id) {
    id
    title
    originalTitle
    year
    overview
    status
    genres
    contentRating
    rating
    tmdbId
    imdbId
    category
    monitored
    addedAt
    seasonCount
    episodeCount
    artwork {
      posterUrl
      backdropUrl
      thumbnailUrl
    }
    seasons {
      seasonNumber
      episodeCount
      airedEpisodeCount
      hasFiles
    }
    nextEpisode {
      id
      seasonNumber
      episodeNumber
      title
      airDate
    }
    nextUp {
      progressState
      episode {
        id
        seasonNumber
        episodeNumber
        title
        runtime
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
    }
    isFavorite
    cast {
      name
      character
      profileUrl
    }
    trailerUrl
    similar {
      id
      type
      title
      year
      artwork {
        posterUrl
        backdropUrl
        thumbnailUrl
      }
    }
  }
}
''';

const String toggleShowFavoriteMutation = r'''
mutation ToggleShowFavorite($id: ID!) {
  toggleShowFavorite(showId: $id) {
    id
    isFavorite
  }
}
''';

ShowDetail _parseShow(Map<String, dynamic> data) {
  final show = data['tvShow'];
  if (show == null) throw Exception('TV show not found');
  return ShowDetail.fromJson(show as Map<String, dynamic>);
}

@riverpod
class ShowDetailController extends _$ShowDetailController {
  late QueryWatcher<ShowDetail> _watcher;

  @override
  Stream<ShowDetail> build(String id) {
    _watcher = createWatcher<ShowDetail>(
      ref,
      key: QueryKeys.showDetail(id),
      document: gql(tvShowDetailQuery),
      variables: {'id': id},
      parse: _parseShow,
    );
    return _watcher.stream;
  }

  Future<void> toggleFavorite() async {
    final currentState = state.value;
    if (currentState == null) return;

    // Captured before the optimistic update, not read after the mutation
    // awaits: this controller is auto-dispose, so if the user navigates away
    // before the server responds, `ref` is torn down and a later
    // `ref.read(invalidatorProvider)` would throw `UnmountedRefException`,
    // silently dropping the invalidation into the revert-on-error catch
    // block below. `Invalidator` itself does not depend on `ref` afterwards.
    final invalidator = ref.read(invalidatorProvider);

    // Optimistically update UI
    state = AsyncValue.data(
      ShowDetail(
        id: currentState.id,
        title: currentState.title,
        originalTitle: currentState.originalTitle,
        year: currentState.year,
        overview: currentState.overview,
        status: currentState.status,
        genres: currentState.genres,
        contentRating: currentState.contentRating,
        rating: currentState.rating,
        tmdbId: currentState.tmdbId,
        imdbId: currentState.imdbId,
        category: currentState.category,
        monitored: currentState.monitored,
        addedAt: currentState.addedAt,
        seasonCount: currentState.seasonCount,
        episodeCount: currentState.episodeCount,
        artwork: currentState.artwork,
        seasons: currentState.seasons,
        nextEpisode: currentState.nextEpisode,
        nextUp: currentState.nextUp,
        isFavorite: !currentState.isFavorite,
        cast: currentState.cast,
        trailerUrl: currentState.trailerUrl,
        similar: currentState.similar,
      ),
    );

    try {
      final client = await ref.read(asyncGraphqlClientProvider.future);
      final result = await client.mutate(
        MutationOptions(
          document: gql(toggleShowFavoriteMutation),
          variables: {'id': currentState.id},
        ),
      );

      if (result.hasException) {
        // Revert on error
        state = AsyncValue.data(currentState);
        throw result.exception!;
      }

      await invalidator.invalidate(
        InvalidationRules.favoriteToggled(
          isMovie: false,
          id: currentState.id,
        ),
      );
    } catch (e) {
      // Revert on error
      state = AsyncValue.data(currentState);
      rethrow;
    }
  }

  Future<void> refresh() => _watcher.refetch();
}

// Provider for selected season state
@riverpod
class SelectedSeason extends _$SelectedSeason {
  @override
  int build(String showId) {
    // Default to season 1
    return 1;
  }

  void select(int seasonNumber) {
    state = seasonNumber;
  }
}
