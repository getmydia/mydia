import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/invalidation_rules.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../core/graphql/watch/watcher_registry.dart';
import '../../../domain/models/movie_detail.dart';
import '../../../domain/models/progress.dart';
import '../../../graphql/mutations/mark_watched.graphql.dart';

part 'movie_detail_controller.g.dart';

const String movieDetailQuery = r'''
query MovieDetail($id: ID!) {
  movie(id: $id) {
    id
    title
    originalTitle
    year
    overview
    runtime
    genres
    contentRating
    rating
    tmdbId
    imdbId
    category
    monitored
    addedAt
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
    isFavorite
  }
}
''';

const String toggleMovieFavoriteMutation = r'''
mutation ToggleMovieFavorite($id: ID!) {
  toggleMovieFavorite(movieId: $id) {
    id
    isFavorite
  }
}
''';

MovieDetail _parseMovie(Map<String, dynamic> data) {
  final movie = data['movie'];
  if (movie == null) throw Exception('Movie not found');
  return MovieDetail.fromJson(movie as Map<String, dynamic>);
}

@riverpod
class MovieDetailController extends _$MovieDetailController {
  late QueryWatcher<MovieDetail> _watcher;

  @override
  Stream<MovieDetail> build(String id) {
    _watcher = createWatcher<MovieDetail>(
      ref,
      key: QueryKeys.movieDetail(id),
      document: gql(movieDetailQuery),
      variables: {'id': id},
      parse: _parseMovie,
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
      currentState.copyWith(isFavorite: !currentState.isFavorite),
    );

    try {
      final client = await ref.read(asyncGraphqlClientProvider.future);
      final result = await client.mutate(
        MutationOptions(
          document: gql(toggleMovieFavoriteMutation),
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
          isMovie: true,
          id: currentState.id,
        ),
      );
    } catch (e) {
      // Revert on error
      state = AsyncValue.data(currentState);
      rethrow;
    }
  }

  /// Marks the movie watched or unwatched.
  ///
  /// Optimistic: the new state lands before the server answers and reverts
  /// on failure, matching the episode-side watched actions.
  Future<void> setWatched(bool watched) async {
    final snapshot = state.value;
    if (snapshot == null) return;

    // Captured before the optimistic update for the same reason as
    // toggleFavorite: this controller is auto-dispose, so reading `ref`
    // after the mutation awaits would throw UnmountedRefException once the
    // user navigates away, silently dropping the invalidation into the
    // revert-on-error catch below.
    final invalidator = ref.read(invalidatorProvider);

    state = AsyncValue.data(applyOptimisticWatched(snapshot, watched));

    try {
      final client = await ref.read(asyncGraphqlClientProvider.future);
      final result = await client.mutate(
        watched
            ? MutationOptions(
                document: documentNodeMutationMarkMovieWatched,
                variables: Variables$Mutation$MarkMovieWatched(
                  movieId: snapshot.id,
                ).toJson(),
              )
            : MutationOptions(
                document: documentNodeMutationMarkMovieUnwatched,
                variables: Variables$Mutation$MarkMovieUnwatched(
                  movieId: snapshot.id,
                ).toJson(),
              ),
      );

      if (result.hasException) {
        state = AsyncValue.data(snapshot);
        throw result.exception!;
      }

      await invalidator.invalidate(
        InvalidationRules.movieWatchedChanged(movieId: snapshot.id),
      );
    } catch (_) {
      state = AsyncValue.data(snapshot);
      rethrow;
    }
  }

  /// Pure helper: returns a copy of [movie] with its watched state set.
  ///
  /// Marking watched preserves any existing position and percentage;
  /// marking unwatched drops the progress row, mirroring the backend's
  /// `delete_progress` semantics.
  static MovieDetail applyOptimisticWatched(MovieDetail movie, bool watched) {
    if (!watched) return movie.copyWith(clearProgress: true);

    final existing = movie.progress;
    return movie.copyWith(
      progress: Progress(
        positionSeconds: existing?.positionSeconds ?? 0,
        durationSeconds: existing?.durationSeconds,
        percentage: existing?.percentage ?? 0,
        watched: true,
        lastWatchedAt:
            existing?.lastWatchedAt ?? DateTime.now().toUtc().toIso8601String(),
      ),
    );
  }

  Future<void> refresh() => _watcher.refetch();
}
