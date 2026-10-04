/// What a source's items look like once mapped out of its server's format.
///
/// Mydia's own screens keep their GraphQL models; these are for the generic
/// per-source screens, which must not know which server kind answered.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/source.dart';

enum ItemKind { movie, show, season, episode, video, folder }

@immutable
class ItemRef {
  const ItemRef({
    required this.sourceId,
    required this.kind,
    required this.externalId,
  });

  final SourceId sourceId;
  final ItemKind kind;

  /// The server's own id: a Plex `ratingKey`, a Stash scene id.
  final String externalId;

  @override
  bool operator ==(Object other) =>
      other is ItemRef &&
      other.sourceId == sourceId &&
      other.kind == kind &&
      other.externalId == externalId;

  @override
  int get hashCode => Object.hash(sourceId, kind, externalId);

  @override
  String toString() => 'ItemRef($sourceId, ${kind.name}, $externalId)';
}

/// A path relative to the source's server. The source turns it into a URL
/// against whichever connection is current, so a connection upgrade never
/// changes what the image cache keys on.
@immutable
class ArtworkRef {
  const ArtworkRef(this.path);

  final String path;

  @override
  bool operator ==(Object other) => other is ArtworkRef && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

@immutable
class Person {
  const Person({required this.name, this.role, this.photo});

  final String name;

  /// The character played.
  final String? role;
  final ArtworkRef? photo;
}

@immutable
class UserState {
  const UserState({this.watched = false, this.progressSeconds});

  final bool watched;

  /// Saved resume position. Null or zero means none.
  final int? progressSeconds;
}

@immutable
class ItemSummary {
  const ItemSummary({
    required this.ref,
    required this.title,
    this.subtitle,
    this.showTitle,
    this.year,
    this.poster,
    this.backdrop,
    this.durationSeconds,
    this.userState = const UserState(),
    this.childCount,
    this.index,
    this.parentIndex,
    this.overview,
    this.airDate,
    this.defaultVersionId,
    this.sortTitle,
    this.addedAt,
    this.lastPlayedAt,
  });

  final ItemRef ref;
  final String title;
  final String? subtitle;

  /// The series an episode belongs to. Null for anything else.
  final String? showTitle;
  final int? year;
  final ArtworkRef? poster;
  final ArtworkRef? backdrop;
  final int? durationSeconds;
  final UserState userState;

  /// Seasons of a show, episodes of a season.
  final int? childCount;

  /// Episode number, or season number for a season.
  final int? index;

  /// Season number of an episode.
  final int? parentIndex;
  final String? overview;

  /// ISO date, `YYYY-MM-DD`.
  final String? airDate;

  /// The version an episode list entry plays by default, when the listing
  /// names one without a detail call.
  final String? defaultVersionId;

  /// The server's sort title, when it has one apart from [title].
  final String? sortTitle;

  /// When the item joined the server's library.
  final DateTime? addedAt;

  /// When this viewer last played it. Null when they never did, or when the
  /// server does not say (a Jellyfin Next Up episode, an unplayed Plex
  /// on-deck item).
  final DateTime? lastPlayedAt;
}

enum MediaStreamKind { audio, subtitle }

@immutable
class MediaStreamInfo {
  const MediaStreamInfo({
    required this.id,
    required this.kind,
    this.codec,
    this.language,
    this.title,
    this.isDefault = false,
    this.externalPath,
  });

  final String id;
  final MediaStreamKind kind;
  final String? codec;

  /// ISO 639 code as the server sent it, two or three letters.
  final String? language;
  final String? title;
  final bool isDefault;

  /// Server path of a sidecar file. Null for a track inside the container.
  final String? externalPath;
}

/// One playable file of an item.
@immutable
class MediaVersion {
  const MediaVersion({
    required this.id,
    this.container,
    this.videoCodec,
    this.audioCodec,
    this.height,
    this.bitrateKbps,
    this.durationSeconds,
    this.streamPath,
    this.streams = const [],
  });

  /// What the player passes as its file id: a Plex part id, a Stash file id.
  final String id;
  final String? container;
  final String? videoCodec;
  final String? audioCodec;
  final int? height;
  final int? bitrateKbps;
  final int? durationSeconds;

  /// Server path that serves the file as-is, when the server names one.
  final String? streamPath;
  final List<MediaStreamInfo> streams;
}

@immutable
class ItemDetail {
  const ItemDetail({
    required this.summary,
    this.overview,
    this.genres = const [],
    this.people = const [],
    this.studio,
    this.tags = const [],
    this.rating,
    this.versions = const [],
    this.cast = const [],
    this.trailerUrl,
    this.contentRating,
    this.isFavorite = false,
    this.show,
    this.season,
  });

  final ItemSummary summary;
  final String? overview;
  final List<String> genres;
  final List<String> people;
  final String? studio;
  final List<String> tags;

  /// Zero to ten.
  final double? rating;
  final List<MediaVersion> versions;
  final List<Person> cast;
  final String? trailerUrl;
  final String? contentRating;
  final bool isFavorite;

  /// For an episode or season: its show. For an episode: its season.
  final ItemRef? show;
  final ItemRef? season;
}
