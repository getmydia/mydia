/// What a detail screen can ask its server to do.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/detail/detail_views.dart';
import '../episode/episode_detail_controller.dart';
import '../movie/movie_detail_controller.dart';
import '../show/season_episodes_controller.dart';
import '../show/show_detail_controller.dart';

abstract interface class MovieActions {
  Future<void> setWatched(bool watched);
  Future<void> toggleFavorite();
  Future<void> refresh();
}

abstract interface class ShowActions {
  Future<void> toggleFavorite();
  Future<void> refresh();
}

enum EpisodeWatchedAction { watched, unwatched, thisAndPrevious }

abstract interface class SeasonActions {
  Future<void> episode(EpisodeView episode, EpisodeWatchedAction action);
  Future<void> setSeasonWatched(bool watched);
  Future<void> refresh();
}

abstract interface class EpisodeActions {
  Future<void> refresh();
}

// The Mydia* classes read `ref` only synchronously, at call time, to fetch the
// notifier. The notifier owns its own awaits.

class MydiaMovieActions implements MovieActions {
  MydiaMovieActions(this._ref, this._id);

  final Ref _ref;
  final String _id;

  MovieDetailController get _c =>
      _ref.read(movieDetailControllerProvider(_id).notifier);

  @override
  Future<void> setWatched(bool watched) => _c.setWatched(watched);

  @override
  Future<void> toggleFavorite() => _c.toggleFavorite();

  @override
  Future<void> refresh() => _c.refresh();
}

class MydiaShowActions implements ShowActions {
  MydiaShowActions(this._ref, this._id);

  final Ref _ref;
  final String _id;

  ShowDetailController get _c =>
      _ref.read(showDetailControllerProvider(_id).notifier);

  @override
  Future<void> toggleFavorite() => _c.toggleFavorite();

  @override
  Future<void> refresh() => _c.refresh();
}

class MydiaSeasonActions implements SeasonActions {
  MydiaSeasonActions(this._ref, this._showId, this._seasonNumber);

  final Ref _ref;
  final String _showId;
  final int _seasonNumber;

  SeasonEpisodesController get _c => _ref.read(
        seasonEpisodesControllerProvider(
          showId: _showId,
          seasonNumber: _seasonNumber,
        ).notifier,
      );

  @override
  Future<void> episode(EpisodeView episode, EpisodeWatchedAction action) {
    final mydia = episode.mydia;
    if (mydia == null) {
      throw StateError('a Mydia season action needs a Mydia episode');
    }
    return switch (action) {
      EpisodeWatchedAction.watched => _c.markEpisodeWatched(mydia),
      EpisodeWatchedAction.unwatched => _c.markEpisodeUnwatched(mydia),
      EpisodeWatchedAction.thisAndPrevious => _c.markThisAndPreviousWatched(
          mydia,
        ),
    };
  }

  @override
  Future<void> setSeasonWatched(bool watched) =>
      watched ? _c.markSeasonWatched() : _c.markSeasonUnwatched();

  @override
  Future<void> refresh() => _c.refresh();
}

class MydiaEpisodeActions implements EpisodeActions {
  MydiaEpisodeActions(this._ref, this._id);

  final Ref _ref;
  final String _id;

  @override
  Future<void> refresh() =>
      _ref.read(episodeDetailControllerProvider(_id).notifier).refresh();
}
