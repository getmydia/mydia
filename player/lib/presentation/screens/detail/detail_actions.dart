/// What a detail screen can ask its server to do.
library;

import '../../../domain/detail/detail_views.dart';

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
