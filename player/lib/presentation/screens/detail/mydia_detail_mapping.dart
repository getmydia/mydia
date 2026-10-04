/// Mydia's GraphQL models as detail views. Pure functions.
library;

import '../../../domain/detail/detail_art.dart';
import '../../../domain/detail/detail_target.dart';
import '../../../domain/detail/detail_views.dart';
import '../../../domain/models/cast_member.dart';
import '../../../domain/models/episode.dart';
import '../../../domain/models/episode_detail.dart';
import '../../../domain/models/movie_detail.dart';
import '../../../domain/models/show_detail.dart';

const mydiaFeatures = {
  DetailFeature.watched,
  DetailFeature.favorite,
  DetailFeature.download,
  DetailFeature.mediaInfo,
  DetailFeature.seasonDownload,
};

DetailArt? _url(String? url) => url == null || url.isEmpty ? null : UrlArt(url);

CastView _cast(CastMember c) =>
    CastView(name: c.name, character: c.character, photo: _url(c.profileUrl));

MovieView movieViewFromMydia(MovieDetail m) => MovieView(
      target: MydiaTarget(DetailKind.movie, m.id),
      title: m.title,
      year: m.year,
      overview: m.overview,
      runtime: m.runtime,
      genres: m.genres,
      contentRating: m.contentRating,
      rating: m.rating,
      backdrop: _url(m.artwork.backdropUrl),
      poster: _url(m.artwork.posterUrl),
      progress: m.progress,
      files: m.files,
      isFavorite: m.isFavorite,
      trailerUrl: m.trailerUrl,
      cast: m.cast.map(_cast).toList(),
      features: mydiaFeatures,
      mydia: m,
    );

ShowView showViewFromMydia(ShowDetail s) => ShowView(
      target: MydiaTarget(DetailKind.show, s.id),
      title: s.title,
      year: s.year,
      overview: s.overview,
      status: s.statusDisplay.isEmpty ? null : s.statusDisplay,
      genres: s.genres,
      contentRating: s.contentRating,
      rating: s.rating,
      backdrop: _url(s.artwork.backdropUrl),
      poster: _url(s.artwork.posterUrl),
      seasons: [
        for (final season in s.seasons)
          SeasonView(
            number: season.seasonNumber,
            watchStatus: season.watchStatus,
            hasFiles: season.hasFiles,
          ),
      ],
      nextUpEpisodeId: s.nextUp?.episode.id,
      nextUpSeasonNumber: s.nextUp?.episode.seasonNumber,
      isFavorite: s.isFavorite,
      trailerUrl: s.trailerUrl,
      cast: s.cast.map(_cast).toList(),
      features: mydiaFeatures,
      mydia: s,
    );

EpisodeView episodeViewFromMydia(Episode e, {required ShowDetail? show}) =>
    EpisodeView(
      target: MydiaTarget(DetailKind.episode, e.id),
      showTarget: show == null ? null : MydiaTarget(DetailKind.show, show.id),
      showTitle: show?.title ?? 'Unknown Show',
      seasonNumber: e.seasonNumber,
      episodeNumber: e.episodeNumber,
      title: e.title,
      overview: e.overview,
      airDate: e.airDate,
      runtime: e.runtime,
      still: _url(e.thumbnailUrl),
      showPoster: _url(show?.artwork.posterUrl),
      progress: e.progress,
      files: e.files,
      hasFile: e.hasFile,
      features: mydiaFeatures,
      mydia: e,
    );

EpisodeView episodeViewFromMydiaDetail(EpisodeDetail e) => EpisodeView(
      target: MydiaTarget(DetailKind.episode, e.id),
      showTarget: MydiaTarget(DetailKind.show, e.show.id),
      showTitle: e.show.title,
      seasonNumber: e.seasonNumber,
      episodeNumber: e.episodeNumber,
      title: e.title,
      overview: e.overview,
      airDate: e.airDate,
      runtime: e.runtime,
      still: _url(e.thumbnailUrl),
      showBackdrop: _url(e.show.artwork.backdropUrl),
      showPoster: _url(e.show.artwork.posterUrl),
      progress: e.progress,
      files: e.files,
      hasFile: e.hasFile,
      features: mydiaFeatures,
      mydiaDetail: e,
    );
