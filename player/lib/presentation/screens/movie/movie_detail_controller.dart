import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../../../core/graphql/graphql_provider.dart';
import '../../../core/graphql/watch/controller_watcher.dart';
import '../../../core/graphql/watch/query_key.dart';
import '../../../core/graphql/watch/query_watcher.dart';
import '../../../domain/models/movie_detail.dart';

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

    final client = ref.read(graphqlClientProvider);
    if (client == null) return;

    // Optimistically update UI
    state = AsyncValue.data(
      MovieDetail(
        id: currentState.id,
        title: currentState.title,
        originalTitle: currentState.originalTitle,
        year: currentState.year,
        overview: currentState.overview,
        runtime: currentState.runtime,
        genres: currentState.genres,
        contentRating: currentState.contentRating,
        rating: currentState.rating,
        tmdbId: currentState.tmdbId,
        imdbId: currentState.imdbId,
        category: currentState.category,
        monitored: currentState.monitored,
        addedAt: currentState.addedAt,
        artwork: currentState.artwork,
        progress: currentState.progress,
        files: currentState.files,
        isFavorite: !currentState.isFavorite,
      ),
    );

    try {
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
    } catch (e) {
      // Revert on error
      state = AsyncValue.data(currentState);
      rethrow;
    }
  }

  Future<void> refresh() => _watcher.refetch();
}
