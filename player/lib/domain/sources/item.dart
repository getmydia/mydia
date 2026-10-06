/// What a source's items look like once mapped out of its server's format.
///
/// Mydia's own screens keep their GraphQL models; these are for the generic
/// per-source screens, which must not know which server kind answered.
library;

import 'package:flutter/foundation.dart';

import '../../core/sources/source.dart';

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.parse(value as String);

ArtworkRef? _art(Object? value) =>
    value == null ? null : ArtworkRef(value as String);

ItemRef? _refOrNull(Object? value) =>
    value == null ? null : ItemRef.fromJson(value as Map<String, Object?>);

List<String> _strings(Object? value) =>
    [for (final s in (value as List?) ?? const []) s as String];

List<T> _list<T>(Object? value, T Function(Map<String, Object?>) item) => [
      for (final e in (value as List?) ?? const [])
        item(e as Map<String, Object?>),
    ];

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

  factory ItemRef.fromJson(Map<String, Object?> json) => ItemRef(
        sourceId: SourceId(json['sourceId']! as String),
        kind: ItemKind.values.byName(json['kind']! as String),
        externalId: json['externalId']! as String,
      );

  Map<String, Object?> toJson() => {
        'sourceId': sourceId.value,
        'kind': kind.name,
        'externalId': externalId,
      };

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

  factory Person.fromJson(Map<String, Object?> json) => Person(
        name: json['name']! as String,
        role: json['role'] as String?,
        photo: _art(json['photo']),
      );

  Map<String, Object?> toJson() =>
      {'name': name, 'role': role, 'photo': photo?.path};
}

@immutable
class UserState {
  const UserState({
    this.watched = false,
    this.progressSeconds,
    this.unwatchedCount,
  });

  final bool watched;

  /// Saved resume position. Null or zero means none.
  final int? progressSeconds;

  /// Unwatched episodes of a show or season. Null for anything else, or when
  /// the server does not say.
  final int? unwatchedCount;

  factory UserState.fromJson(Map<String, Object?> json) => UserState(
        watched: json['watched'] as bool? ?? false,
        progressSeconds: json['progressSeconds'] as int?,
        unwatchedCount: json['unwatchedCount'] as int?,
      );

  Map<String, Object?> toJson() => {
        'watched': watched,
        'progressSeconds': progressSeconds,
        'unwatchedCount': unwatchedCount,
      };
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
    this.showRef,
  });

  final ItemRef ref;
  final String title;

  /// The series an episode belongs to, when the listing names it. Continue
  /// Watching on Mydia dismisses the series, not the episode.
  final ItemRef? showRef;

  /// What "Remove from Continue Watching" dismisses for this entry: the
  /// series when the listing names it, else the item itself. Entries with the
  /// same key are one card's worth of history and leave together.
  ItemRef get dismissRef => showRef ?? ref;
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

  factory ItemSummary.fromJson(Map<String, Object?> json) => ItemSummary(
        ref: ItemRef.fromJson(json['ref']! as Map<String, Object?>),
        title: json['title']! as String,
        subtitle: json['subtitle'] as String?,
        showTitle: json['showTitle'] as String?,
        year: json['year'] as int?,
        poster: _art(json['poster']),
        backdrop: _art(json['backdrop']),
        durationSeconds: json['durationSeconds'] as int?,
        userState: json['userState'] == null
            ? const UserState()
            : UserState.fromJson(json['userState']! as Map<String, Object?>),
        childCount: json['childCount'] as int?,
        index: json['index'] as int?,
        parentIndex: json['parentIndex'] as int?,
        overview: json['overview'] as String?,
        airDate: json['airDate'] as String?,
        defaultVersionId: json['defaultVersionId'] as String?,
        sortTitle: json['sortTitle'] as String?,
        addedAt: _date(json['addedAt']),
        lastPlayedAt: _date(json['lastPlayedAt']),
        showRef: _refOrNull(json['showRef']),
      );

  Map<String, Object?> toJson() => {
        'ref': ref.toJson(),
        'title': title,
        'subtitle': subtitle,
        'showTitle': showTitle,
        'year': year,
        'poster': poster?.path,
        'backdrop': backdrop?.path,
        'durationSeconds': durationSeconds,
        'userState': userState.toJson(),
        'childCount': childCount,
        'index': index,
        'parentIndex': parentIndex,
        'overview': overview,
        'airDate': airDate,
        'defaultVersionId': defaultVersionId,
        'sortTitle': sortTitle,
        'addedAt': addedAt?.toUtc().toIso8601String(),
        'lastPlayedAt': lastPlayedAt?.toUtc().toIso8601String(),
        'showRef': showRef?.toJson(),
      };
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

  factory MediaStreamInfo.fromJson(Map<String, Object?> json) =>
      MediaStreamInfo(
        id: json['id']! as String,
        kind: MediaStreamKind.values.byName(json['kind']! as String),
        codec: json['codec'] as String?,
        language: json['language'] as String?,
        title: json['title'] as String?,
        isDefault: json['isDefault'] as bool? ?? false,
        externalPath: json['externalPath'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'codec': codec,
        'language': language,
        'title': title,
        'isDefault': isDefault,
        'externalPath': externalPath,
      };
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

  factory MediaVersion.fromJson(Map<String, Object?> json) => MediaVersion(
        id: json['id']! as String,
        container: json['container'] as String?,
        videoCodec: json['videoCodec'] as String?,
        audioCodec: json['audioCodec'] as String?,
        height: json['height'] as int?,
        bitrateKbps: json['bitrateKbps'] as int?,
        durationSeconds: json['durationSeconds'] as int?,
        streamPath: json['streamPath'] as String?,
        streams: _list(json['streams'], MediaStreamInfo.fromJson),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'container': container,
        'videoCodec': videoCodec,
        'audioCodec': audioCodec,
        'height': height,
        'bitrateKbps': bitrateKbps,
        'durationSeconds': durationSeconds,
        'streamPath': streamPath,
        'streams': [for (final s in streams) s.toJson()],
      };
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

  factory ItemDetail.fromJson(Map<String, Object?> json) => ItemDetail(
        summary: ItemSummary.fromJson(json['summary']! as Map<String, Object?>),
        overview: json['overview'] as String?,
        genres: _strings(json['genres']),
        people: _strings(json['people']),
        studio: json['studio'] as String?,
        tags: _strings(json['tags']),
        rating: (json['rating'] as num?)?.toDouble(),
        versions: _list(json['versions'], MediaVersion.fromJson),
        cast: _list(json['cast'], Person.fromJson),
        trailerUrl: json['trailerUrl'] as String?,
        contentRating: json['contentRating'] as String?,
        isFavorite: json['isFavorite'] as bool? ?? false,
        show: _refOrNull(json['show']),
        season: _refOrNull(json['season']),
      );

  Map<String, Object?> toJson() => {
        'summary': summary.toJson(),
        'overview': overview,
        'genres': genres,
        'people': people,
        'studio': studio,
        'tags': tags,
        'rating': rating,
        'versions': [for (final v in versions) v.toJson()],
        'cast': [for (final p in cast) p.toJson()],
        'trailerUrl': trailerUrl,
        'contentRating': contentRating,
        'isFavorite': isFavorite,
        'show': show?.toJson(),
        'season': season?.toJson(),
      };
}
