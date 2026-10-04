/// Detail state for Plex and Jellyfin items. Each notifier maps the source's
/// neutral items to the views the shared detail screens render, and carries
/// the optimistic writes (watched, favorite) the Mydia controllers carry.
///
/// Writes capture everything they need before their first await: the notifier
/// is auto-dispose, so `ref` can be gone by the time the server answers (see
/// player/docs/riverpod.md). State is only restored when `ref.mounted`.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/capabilities.dart';
import '../../../core/sources/media_source.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/detail/detail_art.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../../../domain/models/progress.dart';
import '../../../domain/sources/item.dart';
import '../../../domain/sources/source_error.dart';
import '../sources/source_browse_providers.dart';
import 'detail_actions.dart';
import 'source_detail_mapping.dart';

MediaSource _source(Ref ref, SourceId id) =>
    ref.watch(mediaSourceProvider(id)) ??
    (throw const SourceException.notFound());

/// The capability [T] of [item]'s source, read without watching so it is safe
/// at write time. Throws when the source has gone or lacks it.
T _capability<T extends Object>(Ref ref, ItemRef item) {
  final source = ref.read(mediaSourceProvider(item.sourceId)) ??
      (throw const SourceException.notFound());
  return source.as<T>() ?? (throw StateError('the source does not support $T'));
}

/// Everything a finished write should refresh, through the container so it
/// still works if the notifier was disposed while the write was in flight.
void Function() _invalidator(Ref ref, ItemRef item) {
  final container = ref.container;
  return () {
    invalidateSourceContainerWrites(container, item);
    container.invalidate(sourceMovieProvider);
    container.invalidate(sourceShowProvider);
    container.invalidate(sourceSeasonProvider);
    container.invalidate(sourceEpisodeProvider);
  };
}

Progress? _progressWithWatched(Progress? existing, bool watched) {
  if (!watched) return null;
  return Progress(
    positionSeconds: existing?.positionSeconds ?? 0,
    durationSeconds: existing?.durationSeconds,
    percentage: 100,
    watched: true,
    lastWatchedAt: DateTime.now().toUtc().toIso8601String(),
  );
}

EpisodeView _episodeWatched(EpisodeView e, bool watched) => watched
    ? e.copyWith(progress: _progressWithWatched(e.progress, true))
    : e.copyWith(clearProgress: true);

class SourceMovieNotifier extends StreamNotifier<MovieView>
    implements MovieActions {
  SourceMovieNotifier(this.item);

  final ItemRef item;

  @override
  Stream<MovieView> build() async* {
    final source = _source(ref, item.sourceId);
    final detail = await ref.watch(sourceItemProvider(item).future);
    // Cast and trailer arrive with the item on both servers, so there is no
    // second fetch to yield after this one.
    yield movieViewFromSource(detail, features: sourceFeatures(source));
  }

  /// Applies [change] to the loaded view, runs [write], and puts the view
  /// back if the write fails.
  Future<void> _write(
    MovieView Function(MovieView) change,
    Future<void> Function() write,
  ) async {
    final snapshot = state.value;
    if (snapshot == null) return;
    final invalidate = _invalidator(ref, item);
    state = AsyncData(change(snapshot));
    try {
      await write();
      invalidate();
    } catch (_) {
      if (ref.mounted) state = AsyncData(snapshot);
      rethrow;
    }
  }

  @override
  Future<void> setWatched(bool watched) {
    final watchedState = _capability<WatchedState>(ref, item);
    return _write(
      (m) => watched
          ? m.copyWith(progress: _progressWithWatched(m.progress, true))
          : m.copyWith(clearProgress: true),
      () => watchedState.setWatched(item, watched),
    );
  }

  @override
  Future<void> toggleFavorite() {
    final favorites = _capability<Favorites>(ref, item);
    final next = !(state.value?.isFavorite ?? false);
    return _write(
      (m) => m.copyWith(isFavorite: next),
      () => favorites.setFavorite(item, next),
    );
  }

  @override
  Future<void> refresh() async {
    ref.invalidate(sourceItemProvider(item));
    await future;
  }
}

class SourceShowNotifier extends StreamNotifier<ShowView>
    implements ShowActions {
  SourceShowNotifier(this.item);

  final ItemRef item;

  @override
  Stream<ShowView> build() async* {
    final source = _source(ref, item.sourceId);
    final features = sourceFeatures(source);
    final (detail, seasons) = await (
      ref.watch(sourceItemProvider(item).future),
      ref.watch(sourceChildrenProvider(item).future),
    ).wait;
    yield showViewFromSource(detail, seasons, features: features);

    final nextUp = source.as<NextUp>();
    if (nextUp == null) return;
    final ItemSummary? next;
    try {
      next = await nextUp.nextUp(item);
    } catch (_) {
      // Next up only decorates the hero; the show stands without it.
      return;
    }
    if (next != null) {
      yield showViewFromSource(
        detail,
        seasons,
        features: features,
        nextUp: next,
      );
    }
  }

  @override
  Future<void> toggleFavorite() async {
    final snapshot = state.value;
    if (snapshot == null) return;
    final favorites = _capability<Favorites>(ref, item);
    final invalidate = _invalidator(ref, item);
    final next = !snapshot.isFavorite;
    state = AsyncData(snapshot.copyWith(isFavorite: next));
    try {
      await favorites.setFavorite(item, next);
      invalidate();
    } catch (_) {
      if (ref.mounted) state = AsyncData(snapshot);
      rethrow;
    }
  }

  @override
  Future<void> refresh() async {
    ref.invalidate(sourceItemProvider(item));
    ref.invalidate(sourceChildrenProvider(item));
    await future;
  }
}

typedef SourceSeasonKey = ({ItemRef show, int seasonNumber});

class SourceSeasonNotifier extends AsyncNotifier<List<EpisodeView>>
    implements SeasonActions {
  SourceSeasonNotifier(this.key);

  final SourceSeasonKey key;

  ItemRef? _season;

  @override
  Future<List<EpisodeView>> build() async {
    final source = _source(ref, key.show.sourceId);
    // Only the pieces the season needs, so a favorite toggle or a late next
    // up on the show does not refetch the episodes.
    final head = await ref.watch(
      sourceShowProvider(key.show).selectAsync(
        (show) => (
          title: show.title,
          poster: show.poster,
          season: show.seasons
              .where((s) => s.number == key.seasonNumber)
              .map((s) => s.target)
              .firstOrNull,
        ),
      ),
    );
    final seasonTarget = head.season;
    if (seasonTarget is! SourceTarget) {
      throw const SourceException.notFound();
    }
    _season = seasonTarget.ref;
    final children =
        await ref.watch(sourceChildrenProvider(seasonTarget.ref).future);
    final features = sourceFeatures(source);
    final poster = head.poster;
    return [
      for (final e in children)
        episodeViewFromSource(
          e,
          showTitle: head.title,
          showTarget: SourceTarget(key.show),
          showPoster: poster is SourceArt ? poster.ref : null,
          fallbackSeasonNumber: key.seasonNumber,
          features: features,
        ),
    ];
  }

  /// Marks the [affected] episodes optimistically, runs [write], restores the
  /// loaded list on failure.
  Future<void> _write(
    List<EpisodeView> loaded,
    bool Function(EpisodeView) affected,
    bool watched,
    Future<void> Function() write,
  ) async {
    final invalidate = _invalidator(ref, key.show);
    state = AsyncData([
      for (final e in loaded) affected(e) ? _episodeWatched(e, watched) : e,
    ]);
    try {
      await write();
      invalidate();
    } catch (_) {
      if (ref.mounted) state = AsyncData(loaded);
      rethrow;
    }
  }

  @override
  Future<void> episode(EpisodeView episode, EpisodeWatchedAction action) async {
    final loaded = state.value;
    if (loaded == null) return;
    final watchedState = _capability<WatchedState>(ref, key.show);
    final (targets, watched) = switch (action) {
      EpisodeWatchedAction.watched => ([episode], true),
      EpisodeWatchedAction.unwatched => ([episode], false),
      EpisodeWatchedAction.thisAndPrevious => (
          [
            for (final e in loaded)
              if (e.episodeNumber <= episode.episodeNumber) e,
          ],
          true,
        ),
    };
    final ids = {for (final e in targets) e.target};
    await _write(
      loaded,
      (e) => ids.contains(e.target),
      watched,
      () async {
        for (final e in targets) {
          final target = e.target;
          if (target is SourceTarget) {
            await watchedState.setWatched(target.ref, watched);
          }
        }
      },
    );
  }

  @override
  Future<void> setSeasonWatched(bool watched) async {
    final loaded = state.value;
    final season = _season;
    if (loaded == null || season == null) return;
    final watchedState = _capability<WatchedState>(ref, key.show);
    await _write(
      loaded,
      (_) => true,
      watched,
      () => watchedState.setWatched(season, watched),
    );
  }

  @override
  Future<void> refresh() async {
    ref.invalidate(sourceShowProvider(key.show));
    final season = _season;
    if (season != null) ref.invalidate(sourceChildrenProvider(season));
    await future;
  }
}

class SourceEpisodeNotifier extends AsyncNotifier<EpisodeView>
    implements EpisodeActions {
  SourceEpisodeNotifier(this.item);

  final ItemRef item;

  @override
  Future<EpisodeView> build() async {
    final source = _source(ref, item.sourceId);
    final detail = await ref.watch(sourceItemProvider(item).future);
    return episodeViewFromSourceDetail(
      detail,
      features: sourceFeatures(source),
    );
  }

  @override
  Future<void> refresh() async {
    ref.invalidate(sourceItemProvider(item));
    await future;
  }
}

final sourceMovieProvider = StreamNotifierProvider.autoDispose
    .family<SourceMovieNotifier, MovieView, ItemRef>(SourceMovieNotifier.new);

final sourceShowProvider = StreamNotifierProvider.autoDispose
    .family<SourceShowNotifier, ShowView, ItemRef>(SourceShowNotifier.new);

final sourceSeasonProvider = AsyncNotifierProvider.autoDispose
    .family<SourceSeasonNotifier, List<EpisodeView>, SourceSeasonKey>(
        SourceSeasonNotifier.new);

final sourceEpisodeProvider = AsyncNotifierProvider.autoDispose
    .family<SourceEpisodeNotifier, EpisodeView, ItemRef>(
        SourceEpisodeNotifier.new);

/// Empty for a source without the capability. No automatic retry: a failed
/// rail stays hidden rather than polling a down server.
final sourceSimilarProvider =
    FutureProvider.autoDispose.family<List<ItemSummary>, ItemRef>(
  (ref, item) async {
    final similar =
        ref.watch(mediaSourceProvider(item.sourceId))?.as<Similar>();
    return similar == null ? const [] : similar.similar(item);
  },
  retry: (_, __) => null,
);
