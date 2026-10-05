/// Detail state for Plex and Jellyfin items. Each notifier maps the source's
/// neutral items to the views the shared detail screens render, and carries
/// the optimistic writes (watched, favorite) the Mydia controllers carry.
///
/// Writes capture everything they need before their first await: the notifier
/// is auto-dispose, so `ref` can be gone by the time the server answers (see
/// player/docs/riverpod.md). State is only restored when `ref.mounted`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/graphql/watch/watcher_registry.dart';
import '../../../core/sources/cache/create_source_watcher.dart';
import '../../../core/sources/cache/source_codecs.dart';
import '../../../core/sources/cache/source_keys.dart';
import '../../../core/sources/cache/source_rules.dart';
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

/// Awaits [load] for a build that owns [buildRef] (captured before the first
/// await: `ref` itself always points at the current build). A stream-backed
/// provider disposed or rebuilt while loading completes its future with a
/// StateError; once [buildRef] is stale that error belongs to nobody, so it
/// becomes null. While the build is current every error still surfaces.
Future<T?> _awaitWhileCurrent<T>(
    Ref buildRef, Future<T> Function() load) async {
  try {
    return await load();
  } catch (_) {
    if (!buildRef.mounted) return null;
    rethrow;
  }
}

/// What a Future-returning build throws once it is stale: Riverpod discards
/// the result of a build that was replaced, so nobody sees it.
StateError _staleBuild() => StateError('the build was replaced while loading');

/// The capability [T] of [item]'s source, read without watching so it is safe
/// at write time. Throws when the source has gone or lacks it.
T _capability<T extends Object>(Ref ref, ItemRef item) {
  final source = ref.read(mediaSourceProvider(item.sourceId)) ??
      (throw const SourceException.notFound());
  return source.as<T>() ?? (throw StateError('the source does not support $T'));
}

/// What a finished write should refresh, through the container so it still
/// works if the notifier was disposed while the write was in flight.
void Function() _invalidator(Ref ref, ItemRef item) {
  final container = ref.container;
  return () => invalidateSourceDetailWrites(container, item);
}

/// The favorite rule, captured the same way as [_invalidator].
void Function() _favoriteInvalidator(Ref ref, ItemRef item) {
  final container = ref.container;
  return () => unawaited(container
      .read(invalidatorProvider)
      .invalidate(SourceRules.favoriteChanged(item.sourceId)));
}

/// Progress or watched state of [item] changed, here or in the player. The
/// detail notifiers are built on the item and children watchers, which the
/// rule refetches, so they follow on their own.
void invalidateSourceDetailWrites(ProviderContainer container, ItemRef item) =>
    invalidateSourceContainerWrites(container, item);

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
    final buildRef = ref;
    final source = _source(ref, item.sourceId);
    final detail = await _awaitWhileCurrent(
        buildRef, () => ref.watch(sourceItemProvider(item).future));
    if (detail == null) return;
    // Cast and trailer arrive with the item on both servers, so there is no
    // second fetch to yield after this one.
    yield movieViewFromSource(detail, features: sourceFeatures(source));
  }

  /// Applies [change] to the loaded view, runs [write], and puts the view
  /// back if the write fails.
  Future<void> _write(
    MovieView Function(MovieView) change,
    Future<void> Function() write, {
    required void Function() invalidate,
  }) async {
    final snapshot = state.value;
    if (snapshot == null) return;
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
  Future<void> setWatched(bool watched) async {
    final watchedState = _capability<WatchedState>(ref, item);
    await _write(
      (m) => watched
          ? m.copyWith(progress: _progressWithWatched(m.progress, true))
          : m.copyWith(clearProgress: true),
      () => watchedState.setWatched(item, watched),
      invalidate: _invalidator(ref, item),
    );
  }

  @override
  Future<void> toggleFavorite() async {
    final favorites = _capability<Favorites>(ref, item);
    final next = !(state.value?.isFavorite ?? false);
    await _write(
      (m) => m.copyWith(isFavorite: next),
      () => favorites.setFavorite(item, next),
      invalidate: _favoriteInvalidator(ref, item),
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
    final buildRef = ref;
    final source = _source(ref, item.sourceId);
    final features = sourceFeatures(source);
    // A rebuild (after a write, say) keeps the previous Continue target
    // until the new next-up answer lands. A new answer, null included,
    // replaces it.
    final carriedId = state.value?.nextUpEpisodeId;
    final carriedSeason = state.value?.nextUpSeasonNumber;
    final loaded = await _awaitWhileCurrent(
      buildRef,
      () => (
        ref.watch(sourceItemProvider(item).future),
        ref.watch(sourceChildrenProvider(item).future),
      ).wait,
    );
    if (loaded == null) return;
    final (detail, seasons) = loaded;
    final base = showViewFromSource(detail, seasons, features: features);
    final first = carriedId == null
        ? base
        : base.copyWith(
            nextUpEpisodeId: carriedId,
            nextUpSeasonNumber: carriedSeason,
          );
    yield first;

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
      // From the current view, so an optimistic favorite toggle made since
      // the first yield survives.
      yield (state.value ?? first).copyWith(
        nextUpEpisodeId: next.ref.externalId,
        nextUpSeasonNumber: next.parentIndex,
      );
    } else if (carriedId != null) {
      // Nothing left to continue: drop the carried target.
      yield base.copyWith(isFavorite: (state.value ?? first).isFavorite);
    }
  }

  @override
  Future<void> toggleFavorite() async {
    final snapshot = state.value;
    if (snapshot == null) return;
    final favorites = _capability<Favorites>(ref, item);
    final invalidate = _favoriteInvalidator(ref, item);
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
    final buildRef = ref;
    final source = _source(ref, key.show.sourceId);
    // Only the pieces the season needs, so a favorite toggle or a late next
    // up on the show does not refetch the episodes.
    final head = await _awaitWhileCurrent(
      buildRef,
      () => ref.watch(
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
      ),
    );
    if (head == null) throw _staleBuild();
    final seasonTarget = head.season;
    if (seasonTarget is! SourceTarget) {
      throw const SourceException.notFound();
    }
    _season = seasonTarget.ref;
    final children = await _awaitWhileCurrent(buildRef,
        () => ref.watch(sourceChildrenProvider(seasonTarget.ref).future));
    if (children == null) throw _staleBuild();
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
      // A multi-call write may have partly landed: refetch the truth.
      invalidate();
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
    final buildRef = ref;
    final source = _source(ref, item.sourceId);
    final detail = await _awaitWhileCurrent(
        buildRef, () => ref.watch(sourceItemProvider(item).future));
    if (detail == null) throw _staleBuild();
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
    StreamProvider.autoDispose.family<List<ItemSummary>, ItemRef>(
  (ref, item) {
    final similar =
        ref.watch(mediaSourceProvider(item.sourceId))?.as<Similar>();
    if (similar == null) return Stream.value(const []);
    return createSourceWatcher(
      ref,
      key: SourceKeys.similar(item),
      fetch: () => similar.similar(item),
      encode: encodeSummaries,
      decode: decodeSummaries,
    ).stream;
  },
  retry: (_, __) => null,
);
