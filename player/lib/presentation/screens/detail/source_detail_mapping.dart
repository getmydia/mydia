/// A source's neutral items as detail views. Pure functions.
library;

import '../../../core/sources/media_source.dart';
import '../../../core/sources/source.dart';
import '../../../domain/detail/detail_art.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../../../domain/models/media_file.dart';
import '../../../domain/models/progress.dart';
import '../../../domain/models/watch_status.dart';
import '../../../domain/sources/item.dart';

Set<DetailFeature> sourceFeatures(MediaSource source) => {
      if (source.capabilities.contains(SourceCapability.watchedState))
        DetailFeature.watched,
      if (source.capabilities.contains(SourceCapability.favorites))
        DetailFeature.favorite,
    };

DetailArt? _art(SourceId sourceId, ArtworkRef? ref) =>
    ref == null ? null : SourceArt(sourceId, ref);

Progress? progressFromUserState(UserState state, int? durationSeconds) {
  final position = state.progressSeconds ?? 0;
  if (!state.watched && position <= 0) return null;
  final percentage = durationSeconds == null || durationSeconds <= 0
      ? 0.0
      : (position / durationSeconds * 100).clamp(0, 100).toDouble();
  return Progress(
    positionSeconds: position,
    durationSeconds: durationSeconds,
    percentage: state.watched ? 100 : percentage,
    watched: state.watched,
  );
}

List<MediaFile> filesFromVersions(List<MediaVersion> versions) => [
      for (final v in versions)
        MediaFile(
          id: v.id,
          resolution: v.height == null ? null : '${v.height}p',
          codec: v.videoCodec,
          audioCodec: v.audioCodec,
          // MediaFile.bitrate is bits per second; versions carry kilobits.
          bitrate: v.bitrateKbps == null ? null : v.bitrateKbps! * 1000,
          directPlaySupported: true,
        ),
    ];

List<CastView> _cast(SourceId sourceId, List<Person> people) => [
      for (final p in people)
        CastView(
            name: p.name, character: p.role, photo: _art(sourceId, p.photo)),
    ];

int? _minutes(int? seconds) => seconds == null ? null : (seconds / 60).round();

MovieView movieViewFromSource(
  ItemDetail d, {
  required Set<DetailFeature> features,
}) {
  final s = d.summary;
  final id = s.ref.sourceId;
  return MovieView(
    target: SourceTarget(s.ref),
    title: s.title,
    year: s.year,
    overview: d.overview,
    runtime: _minutes(s.durationSeconds),
    genres: d.genres,
    contentRating: d.contentRating,
    rating: d.rating,
    backdrop: _art(id, s.backdrop),
    poster: _art(id, s.poster),
    progress: progressFromUserState(s.userState, s.durationSeconds),
    files: filesFromVersions(d.versions),
    isFavorite: d.isFavorite,
    trailerUrl: d.trailerUrl,
    cast: _cast(id, d.cast),
    features: features,
  );
}

ShowView showViewFromSource(
  ItemDetail d,
  List<ItemSummary> seasons, {
  required Set<DetailFeature> features,
  ItemSummary? nextUp,
}) {
  final s = d.summary;
  final id = s.ref.sourceId;
  return ShowView(
    target: SourceTarget(s.ref),
    title: s.title,
    year: s.year,
    overview: d.overview,
    genres: d.genres,
    contentRating: d.contentRating,
    rating: d.rating,
    backdrop: _art(id, s.backdrop),
    poster: _art(id, s.poster),
    seasons: [
      for (final season in seasons)
        if (season.index case final number?)
          SeasonView(
            number: number,
            target: SourceTarget(season.ref),
            watchStatus: season.userState.watched
                ? const WatchStatus(watched: true)
                : null,
          ),
    ],
    nextUpEpisodeId: nextUp?.ref.externalId,
    nextUpSeasonNumber: nextUp?.parentIndex,
    isFavorite: d.isFavorite,
    trailerUrl: d.trailerUrl,
    cast: _cast(id, d.cast),
    features: features,
  );
}

EpisodeView episodeViewFromSource(
  ItemSummary e, {
  required String showTitle,
  DetailTarget? showTarget,
  ArtworkRef? showPoster,
  int? fallbackSeasonNumber,
  required Set<DetailFeature> features,
}) =>
    EpisodeView(
      target: SourceTarget(e.ref),
      showTarget: showTarget,
      showTitle: e.showTitle ?? showTitle,
      seasonNumber: e.parentIndex ?? fallbackSeasonNumber ?? 0,
      episodeNumber: e.index ?? 0,
      title: e.title,
      overview: e.overview,
      airDate: e.airDate,
      runtime: _minutes(e.durationSeconds),
      still: _art(e.ref.sourceId, e.backdrop),
      showPoster: _art(e.ref.sourceId, showPoster),
      progress: progressFromUserState(e.userState, e.durationSeconds),
      files: [
        if (e.defaultVersionId case final v?)
          MediaFile(id: v, directPlaySupported: true),
      ],
      hasFile: e.defaultVersionId != null,
      features: features,
    );

EpisodeView episodeViewFromSourceDetail(
  ItemDetail d, {
  required Set<DetailFeature> features,
}) {
  final s = d.summary;
  final show = d.show;
  return EpisodeView(
    target: SourceTarget(s.ref),
    showTarget: show == null ? null : SourceTarget(show),
    showTitle: s.showTitle ?? '',
    seasonNumber: s.parentIndex ?? 0,
    episodeNumber: s.index ?? 0,
    title: s.title,
    overview: d.overview,
    airDate: s.airDate,
    runtime: _minutes(s.durationSeconds),
    still: _art(s.ref.sourceId, s.backdrop),
    progress: progressFromUserState(s.userState, s.durationSeconds),
    files: filesFromVersions(d.versions),
    hasFile: d.versions.isNotEmpty,
    features: features,
  );
}
