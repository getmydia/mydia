import '../fragments/artwork_fragment.graphql.dart';
import '../fragments/media_file_fragment.graphql.dart';
import '../schema.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Query$TvShowDetail {
  factory Variables$Query$TvShowDetail({required String id}) =>
      Variables$Query$TvShowDetail._({r'id': id});

  Variables$Query$TvShowDetail._(this._$data);

  factory Variables$Query$TvShowDetail.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    final l$id = data['id'];
    result$data['id'] = (l$id as String);
    return Variables$Query$TvShowDetail._(result$data);
  }

  Map<String, dynamic> _$data;

  String get id => (_$data['id'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$id = id;
    result$data['id'] = l$id;
    return result$data;
  }

  CopyWith$Variables$Query$TvShowDetail<Variables$Query$TvShowDetail>
      get copyWith => CopyWith$Variables$Query$TvShowDetail(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Query$TvShowDetail ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$id = id;
    return Object.hashAll([l$id]);
  }
}

abstract class CopyWith$Variables$Query$TvShowDetail<TRes> {
  factory CopyWith$Variables$Query$TvShowDetail(
    Variables$Query$TvShowDetail instance,
    TRes Function(Variables$Query$TvShowDetail) then,
  ) = _CopyWithImpl$Variables$Query$TvShowDetail;

  factory CopyWith$Variables$Query$TvShowDetail.stub(TRes res) =
      _CopyWithStubImpl$Variables$Query$TvShowDetail;

  TRes call({String? id});
}

class _CopyWithImpl$Variables$Query$TvShowDetail<TRes>
    implements CopyWith$Variables$Query$TvShowDetail<TRes> {
  _CopyWithImpl$Variables$Query$TvShowDetail(this._instance, this._then);

  final Variables$Query$TvShowDetail _instance;

  final TRes Function(Variables$Query$TvShowDetail) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? id = _undefined}) => _then(
        Variables$Query$TvShowDetail._({
          ..._instance._$data,
          if (id != _undefined && id != null) 'id': (id as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Query$TvShowDetail<TRes>
    implements CopyWith$Variables$Query$TvShowDetail<TRes> {
  _CopyWithStubImpl$Variables$Query$TvShowDetail(this._res);

  TRes _res;

  call({String? id}) => _res;
}

class Query$TvShowDetail {
  Query$TvShowDetail({this.tvShow, this.$__typename = 'RootQueryType'});

  factory Query$TvShowDetail.fromJson(Map<String, dynamic> json) {
    final l$tvShow = json['tvShow'];
    final l$$__typename = json['__typename'];
    return Query$TvShowDetail(
      tvShow: l$tvShow == null
          ? null
          : Query$TvShowDetail$tvShow.fromJson(
              (l$tvShow as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Query$TvShowDetail$tvShow? tvShow;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$tvShow = tvShow;
    _resultData['tvShow'] = l$tvShow?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$tvShow = tvShow;
    final l$$__typename = $__typename;
    return Object.hashAll([l$tvShow, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$TvShowDetail || runtimeType != other.runtimeType) {
      return false;
    }
    final l$tvShow = tvShow;
    final lOther$tvShow = other.tvShow;
    if (l$tvShow != lOther$tvShow) {
      return false;
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$TvShowDetail on Query$TvShowDetail {
  CopyWith$Query$TvShowDetail<Query$TvShowDetail> get copyWith =>
      CopyWith$Query$TvShowDetail(this, (i) => i);
}

abstract class CopyWith$Query$TvShowDetail<TRes> {
  factory CopyWith$Query$TvShowDetail(
    Query$TvShowDetail instance,
    TRes Function(Query$TvShowDetail) then,
  ) = _CopyWithImpl$Query$TvShowDetail;

  factory CopyWith$Query$TvShowDetail.stub(TRes res) =
      _CopyWithStubImpl$Query$TvShowDetail;

  TRes call({Query$TvShowDetail$tvShow? tvShow, String? $__typename});
  CopyWith$Query$TvShowDetail$tvShow<TRes> get tvShow;
}

class _CopyWithImpl$Query$TvShowDetail<TRes>
    implements CopyWith$Query$TvShowDetail<TRes> {
  _CopyWithImpl$Query$TvShowDetail(this._instance, this._then);

  final Query$TvShowDetail _instance;

  final TRes Function(Query$TvShowDetail) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? tvShow = _undefined, Object? $__typename = _undefined}) =>
      _then(
        Query$TvShowDetail(
          tvShow: tvShow == _undefined
              ? _instance.tvShow
              : (tvShow as Query$TvShowDetail$tvShow?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Query$TvShowDetail$tvShow<TRes> get tvShow {
    final local$tvShow = _instance.tvShow;
    return local$tvShow == null
        ? CopyWith$Query$TvShowDetail$tvShow.stub(_then(_instance))
        : CopyWith$Query$TvShowDetail$tvShow(
            local$tvShow,
            (e) => call(tvShow: e),
          );
  }
}

class _CopyWithStubImpl$Query$TvShowDetail<TRes>
    implements CopyWith$Query$TvShowDetail<TRes> {
  _CopyWithStubImpl$Query$TvShowDetail(this._res);

  TRes _res;

  call({Query$TvShowDetail$tvShow? tvShow, String? $__typename}) => _res;

  CopyWith$Query$TvShowDetail$tvShow<TRes> get tvShow =>
      CopyWith$Query$TvShowDetail$tvShow.stub(_res);
}

const documentNodeQueryTvShowDetail = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.query,
      name: NameNode(value: 'TvShowDetail'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'id')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'tvShow'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'id'),
                value: VariableNode(name: NameNode(value: 'id')),
              ),
            ],
            directives: [],
            selectionSet: SelectionSetNode(
              selections: [
                FieldNode(
                  name: NameNode(value: 'id'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'title'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'originalTitle'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'year'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'overview'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'status'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'genres'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'contentRating'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'rating'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'tmdbId'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'imdbId'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'category'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'monitored'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'addedAt'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'seasonCount'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'episodeCount'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'artwork'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: SelectionSetNode(
                    selections: [
                      FragmentSpreadNode(
                        name: NameNode(value: 'ArtworkFragment'),
                        directives: [],
                      ),
                      FieldNode(
                        name: NameNode(value: '__typename'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                    ],
                  ),
                ),
                FieldNode(
                  name: NameNode(value: 'seasons'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: SelectionSetNode(
                    selections: [
                      FieldNode(
                        name: NameNode(value: 'seasonNumber'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'episodeCount'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'airedEpisodeCount'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'hasFiles'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: '__typename'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                    ],
                  ),
                ),
                FieldNode(
                  name: NameNode(value: 'nextEpisode'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: SelectionSetNode(
                    selections: [
                      FieldNode(
                        name: NameNode(value: 'id'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'seasonNumber'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'episodeNumber'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'title'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'airDate'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'files'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: SelectionSetNode(
                          selections: [
                            FragmentSpreadNode(
                              name: NameNode(value: 'MediaFileFragment'),
                              directives: [],
                            ),
                            FieldNode(
                              name: NameNode(value: '__typename'),
                              alias: null,
                              arguments: [],
                              directives: [],
                              selectionSet: null,
                            ),
                          ],
                        ),
                      ),
                      FieldNode(
                        name: NameNode(value: '__typename'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                    ],
                  ),
                ),
                FieldNode(
                  name: NameNode(value: 'isFavorite'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: '__typename'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
              ],
            ),
          ),
          FieldNode(
            name: NameNode(value: '__typename'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
        ],
      ),
    ),
    fragmentDefinitionArtworkFragment,
    fragmentDefinitionMediaFileFragment,
  ],
);

class Query$TvShowDetail$tvShow {
  Query$TvShowDetail$tvShow({
    required this.id,
    required this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.status,
    this.genres,
    this.contentRating,
    this.rating,
    this.tmdbId,
    this.imdbId,
    this.category,
    required this.monitored,
    required this.addedAt,
    this.seasonCount,
    this.episodeCount,
    this.artwork,
    this.seasons,
    this.nextEpisode,
    required this.isFavorite,
    this.$__typename = 'TvShow',
  });

  factory Query$TvShowDetail$tvShow.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$title = json['title'];
    final l$originalTitle = json['originalTitle'];
    final l$year = json['year'];
    final l$overview = json['overview'];
    final l$status = json['status'];
    final l$genres = json['genres'];
    final l$contentRating = json['contentRating'];
    final l$rating = json['rating'];
    final l$tmdbId = json['tmdbId'];
    final l$imdbId = json['imdbId'];
    final l$category = json['category'];
    final l$monitored = json['monitored'];
    final l$addedAt = json['addedAt'];
    final l$seasonCount = json['seasonCount'];
    final l$episodeCount = json['episodeCount'];
    final l$artwork = json['artwork'];
    final l$seasons = json['seasons'];
    final l$nextEpisode = json['nextEpisode'];
    final l$isFavorite = json['isFavorite'];
    final l$$__typename = json['__typename'];
    return Query$TvShowDetail$tvShow(
      id: (l$id as String),
      title: (l$title as String),
      originalTitle: (l$originalTitle as String?),
      year: (l$year as int?),
      overview: (l$overview as String?),
      status: (l$status as String?),
      genres: (l$genres as List<dynamic>?)?.map((e) => (e as String?)).toList(),
      contentRating: (l$contentRating as String?),
      rating: (l$rating as num?)?.toDouble(),
      tmdbId: (l$tmdbId as int?),
      imdbId: (l$imdbId as String?),
      category: l$category == null
          ? null
          : fromJson$Enum$MediaCategory((l$category as String)),
      monitored: (l$monitored as bool),
      addedAt: (l$addedAt as String),
      seasonCount: (l$seasonCount as int?),
      episodeCount: (l$episodeCount as int?),
      artwork: l$artwork == null
          ? null
          : Fragment$ArtworkFragment.fromJson(
              (l$artwork as Map<String, dynamic>),
            ),
      seasons: (l$seasons as List<dynamic>?)
          ?.map(
            (e) => e == null
                ? null
                : Query$TvShowDetail$tvShow$seasons.fromJson(
                    (e as Map<String, dynamic>),
                  ),
          )
          .toList(),
      nextEpisode: l$nextEpisode == null
          ? null
          : Query$TvShowDetail$tvShow$nextEpisode.fromJson(
              (l$nextEpisode as Map<String, dynamic>),
            ),
      isFavorite: (l$isFavorite as bool),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String title;

  final String? originalTitle;

  final int? year;

  final String? overview;

  final String? status;

  final List<String?>? genres;

  final String? contentRating;

  final double? rating;

  final int? tmdbId;

  final String? imdbId;

  final Enum$MediaCategory? category;

  final bool monitored;

  final String addedAt;

  final int? seasonCount;

  final int? episodeCount;

  final Fragment$ArtworkFragment? artwork;

  final List<Query$TvShowDetail$tvShow$seasons?>? seasons;

  final Query$TvShowDetail$tvShow$nextEpisode? nextEpisode;

  final bool isFavorite;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$originalTitle = originalTitle;
    _resultData['originalTitle'] = l$originalTitle;
    final l$year = year;
    _resultData['year'] = l$year;
    final l$overview = overview;
    _resultData['overview'] = l$overview;
    final l$status = status;
    _resultData['status'] = l$status;
    final l$genres = genres;
    _resultData['genres'] = l$genres?.map((e) => e).toList();
    final l$contentRating = contentRating;
    _resultData['contentRating'] = l$contentRating;
    final l$rating = rating;
    _resultData['rating'] = l$rating;
    final l$tmdbId = tmdbId;
    _resultData['tmdbId'] = l$tmdbId;
    final l$imdbId = imdbId;
    _resultData['imdbId'] = l$imdbId;
    final l$category = category;
    _resultData['category'] =
        l$category == null ? null : toJson$Enum$MediaCategory(l$category);
    final l$monitored = monitored;
    _resultData['monitored'] = l$monitored;
    final l$addedAt = addedAt;
    _resultData['addedAt'] = l$addedAt;
    final l$seasonCount = seasonCount;
    _resultData['seasonCount'] = l$seasonCount;
    final l$episodeCount = episodeCount;
    _resultData['episodeCount'] = l$episodeCount;
    final l$artwork = artwork;
    _resultData['artwork'] = l$artwork?.toJson();
    final l$seasons = seasons;
    _resultData['seasons'] = l$seasons?.map((e) => e?.toJson()).toList();
    final l$nextEpisode = nextEpisode;
    _resultData['nextEpisode'] = l$nextEpisode?.toJson();
    final l$isFavorite = isFavorite;
    _resultData['isFavorite'] = l$isFavorite;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$title = title;
    final l$originalTitle = originalTitle;
    final l$year = year;
    final l$overview = overview;
    final l$status = status;
    final l$genres = genres;
    final l$contentRating = contentRating;
    final l$rating = rating;
    final l$tmdbId = tmdbId;
    final l$imdbId = imdbId;
    final l$category = category;
    final l$monitored = monitored;
    final l$addedAt = addedAt;
    final l$seasonCount = seasonCount;
    final l$episodeCount = episodeCount;
    final l$artwork = artwork;
    final l$seasons = seasons;
    final l$nextEpisode = nextEpisode;
    final l$isFavorite = isFavorite;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$title,
      l$originalTitle,
      l$year,
      l$overview,
      l$status,
      l$genres == null ? null : Object.hashAll(l$genres.map((v) => v)),
      l$contentRating,
      l$rating,
      l$tmdbId,
      l$imdbId,
      l$category,
      l$monitored,
      l$addedAt,
      l$seasonCount,
      l$episodeCount,
      l$artwork,
      l$seasons == null ? null : Object.hashAll(l$seasons.map((v) => v)),
      l$nextEpisode,
      l$isFavorite,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$TvShowDetail$tvShow ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$title = title;
    final lOther$title = other.title;
    if (l$title != lOther$title) {
      return false;
    }
    final l$originalTitle = originalTitle;
    final lOther$originalTitle = other.originalTitle;
    if (l$originalTitle != lOther$originalTitle) {
      return false;
    }
    final l$year = year;
    final lOther$year = other.year;
    if (l$year != lOther$year) {
      return false;
    }
    final l$overview = overview;
    final lOther$overview = other.overview;
    if (l$overview != lOther$overview) {
      return false;
    }
    final l$status = status;
    final lOther$status = other.status;
    if (l$status != lOther$status) {
      return false;
    }
    final l$genres = genres;
    final lOther$genres = other.genres;
    if (l$genres != null && lOther$genres != null) {
      if (l$genres.length != lOther$genres.length) {
        return false;
      }
      for (int i = 0; i < l$genres.length; i++) {
        final l$genres$entry = l$genres[i];
        final lOther$genres$entry = lOther$genres[i];
        if (l$genres$entry != lOther$genres$entry) {
          return false;
        }
      }
    } else if (l$genres != lOther$genres) {
      return false;
    }
    final l$contentRating = contentRating;
    final lOther$contentRating = other.contentRating;
    if (l$contentRating != lOther$contentRating) {
      return false;
    }
    final l$rating = rating;
    final lOther$rating = other.rating;
    if (l$rating != lOther$rating) {
      return false;
    }
    final l$tmdbId = tmdbId;
    final lOther$tmdbId = other.tmdbId;
    if (l$tmdbId != lOther$tmdbId) {
      return false;
    }
    final l$imdbId = imdbId;
    final lOther$imdbId = other.imdbId;
    if (l$imdbId != lOther$imdbId) {
      return false;
    }
    final l$category = category;
    final lOther$category = other.category;
    if (l$category != lOther$category) {
      return false;
    }
    final l$monitored = monitored;
    final lOther$monitored = other.monitored;
    if (l$monitored != lOther$monitored) {
      return false;
    }
    final l$addedAt = addedAt;
    final lOther$addedAt = other.addedAt;
    if (l$addedAt != lOther$addedAt) {
      return false;
    }
    final l$seasonCount = seasonCount;
    final lOther$seasonCount = other.seasonCount;
    if (l$seasonCount != lOther$seasonCount) {
      return false;
    }
    final l$episodeCount = episodeCount;
    final lOther$episodeCount = other.episodeCount;
    if (l$episodeCount != lOther$episodeCount) {
      return false;
    }
    final l$artwork = artwork;
    final lOther$artwork = other.artwork;
    if (l$artwork != lOther$artwork) {
      return false;
    }
    final l$seasons = seasons;
    final lOther$seasons = other.seasons;
    if (l$seasons != null && lOther$seasons != null) {
      if (l$seasons.length != lOther$seasons.length) {
        return false;
      }
      for (int i = 0; i < l$seasons.length; i++) {
        final l$seasons$entry = l$seasons[i];
        final lOther$seasons$entry = lOther$seasons[i];
        if (l$seasons$entry != lOther$seasons$entry) {
          return false;
        }
      }
    } else if (l$seasons != lOther$seasons) {
      return false;
    }
    final l$nextEpisode = nextEpisode;
    final lOther$nextEpisode = other.nextEpisode;
    if (l$nextEpisode != lOther$nextEpisode) {
      return false;
    }
    final l$isFavorite = isFavorite;
    final lOther$isFavorite = other.isFavorite;
    if (l$isFavorite != lOther$isFavorite) {
      return false;
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$TvShowDetail$tvShow
    on Query$TvShowDetail$tvShow {
  CopyWith$Query$TvShowDetail$tvShow<Query$TvShowDetail$tvShow> get copyWith =>
      CopyWith$Query$TvShowDetail$tvShow(this, (i) => i);
}

abstract class CopyWith$Query$TvShowDetail$tvShow<TRes> {
  factory CopyWith$Query$TvShowDetail$tvShow(
    Query$TvShowDetail$tvShow instance,
    TRes Function(Query$TvShowDetail$tvShow) then,
  ) = _CopyWithImpl$Query$TvShowDetail$tvShow;

  factory CopyWith$Query$TvShowDetail$tvShow.stub(TRes res) =
      _CopyWithStubImpl$Query$TvShowDetail$tvShow;

  TRes call({
    String? id,
    String? title,
    String? originalTitle,
    int? year,
    String? overview,
    String? status,
    List<String?>? genres,
    String? contentRating,
    double? rating,
    int? tmdbId,
    String? imdbId,
    Enum$MediaCategory? category,
    bool? monitored,
    String? addedAt,
    int? seasonCount,
    int? episodeCount,
    Fragment$ArtworkFragment? artwork,
    List<Query$TvShowDetail$tvShow$seasons?>? seasons,
    Query$TvShowDetail$tvShow$nextEpisode? nextEpisode,
    bool? isFavorite,
    String? $__typename,
  });
  CopyWith$Fragment$ArtworkFragment<TRes> get artwork;
  TRes seasons(
    Iterable<Query$TvShowDetail$tvShow$seasons?>? Function(
      Iterable<
          CopyWith$Query$TvShowDetail$tvShow$seasons<
              Query$TvShowDetail$tvShow$seasons>?>?,
    ) _fn,
  );
  CopyWith$Query$TvShowDetail$tvShow$nextEpisode<TRes> get nextEpisode;
}

class _CopyWithImpl$Query$TvShowDetail$tvShow<TRes>
    implements CopyWith$Query$TvShowDetail$tvShow<TRes> {
  _CopyWithImpl$Query$TvShowDetail$tvShow(this._instance, this._then);

  final Query$TvShowDetail$tvShow _instance;

  final TRes Function(Query$TvShowDetail$tvShow) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? title = _undefined,
    Object? originalTitle = _undefined,
    Object? year = _undefined,
    Object? overview = _undefined,
    Object? status = _undefined,
    Object? genres = _undefined,
    Object? contentRating = _undefined,
    Object? rating = _undefined,
    Object? tmdbId = _undefined,
    Object? imdbId = _undefined,
    Object? category = _undefined,
    Object? monitored = _undefined,
    Object? addedAt = _undefined,
    Object? seasonCount = _undefined,
    Object? episodeCount = _undefined,
    Object? artwork = _undefined,
    Object? seasons = _undefined,
    Object? nextEpisode = _undefined,
    Object? isFavorite = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$TvShowDetail$tvShow(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          title: title == _undefined || title == null
              ? _instance.title
              : (title as String),
          originalTitle: originalTitle == _undefined
              ? _instance.originalTitle
              : (originalTitle as String?),
          year: year == _undefined ? _instance.year : (year as int?),
          overview: overview == _undefined
              ? _instance.overview
              : (overview as String?),
          status: status == _undefined ? _instance.status : (status as String?),
          genres: genres == _undefined
              ? _instance.genres
              : (genres as List<String?>?),
          contentRating: contentRating == _undefined
              ? _instance.contentRating
              : (contentRating as String?),
          rating: rating == _undefined ? _instance.rating : (rating as double?),
          tmdbId: tmdbId == _undefined ? _instance.tmdbId : (tmdbId as int?),
          imdbId: imdbId == _undefined ? _instance.imdbId : (imdbId as String?),
          category: category == _undefined
              ? _instance.category
              : (category as Enum$MediaCategory?),
          monitored: monitored == _undefined || monitored == null
              ? _instance.monitored
              : (monitored as bool),
          addedAt: addedAt == _undefined || addedAt == null
              ? _instance.addedAt
              : (addedAt as String),
          seasonCount: seasonCount == _undefined
              ? _instance.seasonCount
              : (seasonCount as int?),
          episodeCount: episodeCount == _undefined
              ? _instance.episodeCount
              : (episodeCount as int?),
          artwork: artwork == _undefined
              ? _instance.artwork
              : (artwork as Fragment$ArtworkFragment?),
          seasons: seasons == _undefined
              ? _instance.seasons
              : (seasons as List<Query$TvShowDetail$tvShow$seasons?>?),
          nextEpisode: nextEpisode == _undefined
              ? _instance.nextEpisode
              : (nextEpisode as Query$TvShowDetail$tvShow$nextEpisode?),
          isFavorite: isFavorite == _undefined || isFavorite == null
              ? _instance.isFavorite
              : (isFavorite as bool),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork {
    final local$artwork = _instance.artwork;
    return local$artwork == null
        ? CopyWith$Fragment$ArtworkFragment.stub(_then(_instance))
        : CopyWith$Fragment$ArtworkFragment(
            local$artwork,
            (e) => call(artwork: e),
          );
  }

  TRes seasons(
    Iterable<Query$TvShowDetail$tvShow$seasons?>? Function(
      Iterable<
          CopyWith$Query$TvShowDetail$tvShow$seasons<
              Query$TvShowDetail$tvShow$seasons>?>?,
    ) _fn,
  ) =>
      call(
        seasons: _fn(
          _instance.seasons?.map(
            (e) => e == null
                ? null
                : CopyWith$Query$TvShowDetail$tvShow$seasons(e, (i) => i),
          ),
        )?.toList(),
      );

  CopyWith$Query$TvShowDetail$tvShow$nextEpisode<TRes> get nextEpisode {
    final local$nextEpisode = _instance.nextEpisode;
    return local$nextEpisode == null
        ? CopyWith$Query$TvShowDetail$tvShow$nextEpisode.stub(_then(_instance))
        : CopyWith$Query$TvShowDetail$tvShow$nextEpisode(
            local$nextEpisode,
            (e) => call(nextEpisode: e),
          );
  }
}

class _CopyWithStubImpl$Query$TvShowDetail$tvShow<TRes>
    implements CopyWith$Query$TvShowDetail$tvShow<TRes> {
  _CopyWithStubImpl$Query$TvShowDetail$tvShow(this._res);

  TRes _res;

  call({
    String? id,
    String? title,
    String? originalTitle,
    int? year,
    String? overview,
    String? status,
    List<String?>? genres,
    String? contentRating,
    double? rating,
    int? tmdbId,
    String? imdbId,
    Enum$MediaCategory? category,
    bool? monitored,
    String? addedAt,
    int? seasonCount,
    int? episodeCount,
    Fragment$ArtworkFragment? artwork,
    List<Query$TvShowDetail$tvShow$seasons?>? seasons,
    Query$TvShowDetail$tvShow$nextEpisode? nextEpisode,
    bool? isFavorite,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork =>
      CopyWith$Fragment$ArtworkFragment.stub(_res);

  seasons(_fn) => _res;

  CopyWith$Query$TvShowDetail$tvShow$nextEpisode<TRes> get nextEpisode =>
      CopyWith$Query$TvShowDetail$tvShow$nextEpisode.stub(_res);
}

class Query$TvShowDetail$tvShow$seasons {
  Query$TvShowDetail$tvShow$seasons({
    required this.seasonNumber,
    required this.episodeCount,
    this.airedEpisodeCount,
    required this.hasFiles,
    this.$__typename = 'Season',
  });

  factory Query$TvShowDetail$tvShow$seasons.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$seasonNumber = json['seasonNumber'];
    final l$episodeCount = json['episodeCount'];
    final l$airedEpisodeCount = json['airedEpisodeCount'];
    final l$hasFiles = json['hasFiles'];
    final l$$__typename = json['__typename'];
    return Query$TvShowDetail$tvShow$seasons(
      seasonNumber: (l$seasonNumber as int),
      episodeCount: (l$episodeCount as int),
      airedEpisodeCount: (l$airedEpisodeCount as int?),
      hasFiles: (l$hasFiles as bool),
      $__typename: (l$$__typename as String),
    );
  }

  final int seasonNumber;

  final int episodeCount;

  final int? airedEpisodeCount;

  final bool hasFiles;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$seasonNumber = seasonNumber;
    _resultData['seasonNumber'] = l$seasonNumber;
    final l$episodeCount = episodeCount;
    _resultData['episodeCount'] = l$episodeCount;
    final l$airedEpisodeCount = airedEpisodeCount;
    _resultData['airedEpisodeCount'] = l$airedEpisodeCount;
    final l$hasFiles = hasFiles;
    _resultData['hasFiles'] = l$hasFiles;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$seasonNumber = seasonNumber;
    final l$episodeCount = episodeCount;
    final l$airedEpisodeCount = airedEpisodeCount;
    final l$hasFiles = hasFiles;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$seasonNumber,
      l$episodeCount,
      l$airedEpisodeCount,
      l$hasFiles,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$TvShowDetail$tvShow$seasons ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$seasonNumber = seasonNumber;
    final lOther$seasonNumber = other.seasonNumber;
    if (l$seasonNumber != lOther$seasonNumber) {
      return false;
    }
    final l$episodeCount = episodeCount;
    final lOther$episodeCount = other.episodeCount;
    if (l$episodeCount != lOther$episodeCount) {
      return false;
    }
    final l$airedEpisodeCount = airedEpisodeCount;
    final lOther$airedEpisodeCount = other.airedEpisodeCount;
    if (l$airedEpisodeCount != lOther$airedEpisodeCount) {
      return false;
    }
    final l$hasFiles = hasFiles;
    final lOther$hasFiles = other.hasFiles;
    if (l$hasFiles != lOther$hasFiles) {
      return false;
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$TvShowDetail$tvShow$seasons
    on Query$TvShowDetail$tvShow$seasons {
  CopyWith$Query$TvShowDetail$tvShow$seasons<Query$TvShowDetail$tvShow$seasons>
      get copyWith =>
          CopyWith$Query$TvShowDetail$tvShow$seasons(this, (i) => i);
}

abstract class CopyWith$Query$TvShowDetail$tvShow$seasons<TRes> {
  factory CopyWith$Query$TvShowDetail$tvShow$seasons(
    Query$TvShowDetail$tvShow$seasons instance,
    TRes Function(Query$TvShowDetail$tvShow$seasons) then,
  ) = _CopyWithImpl$Query$TvShowDetail$tvShow$seasons;

  factory CopyWith$Query$TvShowDetail$tvShow$seasons.stub(TRes res) =
      _CopyWithStubImpl$Query$TvShowDetail$tvShow$seasons;

  TRes call({
    int? seasonNumber,
    int? episodeCount,
    int? airedEpisodeCount,
    bool? hasFiles,
    String? $__typename,
  });
}

class _CopyWithImpl$Query$TvShowDetail$tvShow$seasons<TRes>
    implements CopyWith$Query$TvShowDetail$tvShow$seasons<TRes> {
  _CopyWithImpl$Query$TvShowDetail$tvShow$seasons(this._instance, this._then);

  final Query$TvShowDetail$tvShow$seasons _instance;

  final TRes Function(Query$TvShowDetail$tvShow$seasons) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? seasonNumber = _undefined,
    Object? episodeCount = _undefined,
    Object? airedEpisodeCount = _undefined,
    Object? hasFiles = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$TvShowDetail$tvShow$seasons(
          seasonNumber: seasonNumber == _undefined || seasonNumber == null
              ? _instance.seasonNumber
              : (seasonNumber as int),
          episodeCount: episodeCount == _undefined || episodeCount == null
              ? _instance.episodeCount
              : (episodeCount as int),
          airedEpisodeCount: airedEpisodeCount == _undefined
              ? _instance.airedEpisodeCount
              : (airedEpisodeCount as int?),
          hasFiles: hasFiles == _undefined || hasFiles == null
              ? _instance.hasFiles
              : (hasFiles as bool),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Query$TvShowDetail$tvShow$seasons<TRes>
    implements CopyWith$Query$TvShowDetail$tvShow$seasons<TRes> {
  _CopyWithStubImpl$Query$TvShowDetail$tvShow$seasons(this._res);

  TRes _res;

  call({
    int? seasonNumber,
    int? episodeCount,
    int? airedEpisodeCount,
    bool? hasFiles,
    String? $__typename,
  }) =>
      _res;
}

class Query$TvShowDetail$tvShow$nextEpisode {
  Query$TvShowDetail$tvShow$nextEpisode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    this.title,
    this.airDate,
    this.files,
    this.$__typename = 'Episode',
  });

  factory Query$TvShowDetail$tvShow$nextEpisode.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$seasonNumber = json['seasonNumber'];
    final l$episodeNumber = json['episodeNumber'];
    final l$title = json['title'];
    final l$airDate = json['airDate'];
    final l$files = json['files'];
    final l$$__typename = json['__typename'];
    return Query$TvShowDetail$tvShow$nextEpisode(
      id: (l$id as String),
      seasonNumber: (l$seasonNumber as int),
      episodeNumber: (l$episodeNumber as int),
      title: (l$title as String?),
      airDate: (l$airDate as String?),
      files: (l$files as List<dynamic>?)
          ?.map(
            (e) => e == null
                ? null
                : Fragment$MediaFileFragment.fromJson(
                    (e as Map<String, dynamic>),
                  ),
          )
          .toList(),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final int seasonNumber;

  final int episodeNumber;

  final String? title;

  final String? airDate;

  final List<Fragment$MediaFileFragment?>? files;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$seasonNumber = seasonNumber;
    _resultData['seasonNumber'] = l$seasonNumber;
    final l$episodeNumber = episodeNumber;
    _resultData['episodeNumber'] = l$episodeNumber;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$airDate = airDate;
    _resultData['airDate'] = l$airDate;
    final l$files = files;
    _resultData['files'] = l$files?.map((e) => e?.toJson()).toList();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$seasonNumber = seasonNumber;
    final l$episodeNumber = episodeNumber;
    final l$title = title;
    final l$airDate = airDate;
    final l$files = files;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$seasonNumber,
      l$episodeNumber,
      l$title,
      l$airDate,
      l$files == null ? null : Object.hashAll(l$files.map((v) => v)),
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$TvShowDetail$tvShow$nextEpisode ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$seasonNumber = seasonNumber;
    final lOther$seasonNumber = other.seasonNumber;
    if (l$seasonNumber != lOther$seasonNumber) {
      return false;
    }
    final l$episodeNumber = episodeNumber;
    final lOther$episodeNumber = other.episodeNumber;
    if (l$episodeNumber != lOther$episodeNumber) {
      return false;
    }
    final l$title = title;
    final lOther$title = other.title;
    if (l$title != lOther$title) {
      return false;
    }
    final l$airDate = airDate;
    final lOther$airDate = other.airDate;
    if (l$airDate != lOther$airDate) {
      return false;
    }
    final l$files = files;
    final lOther$files = other.files;
    if (l$files != null && lOther$files != null) {
      if (l$files.length != lOther$files.length) {
        return false;
      }
      for (int i = 0; i < l$files.length; i++) {
        final l$files$entry = l$files[i];
        final lOther$files$entry = lOther$files[i];
        if (l$files$entry != lOther$files$entry) {
          return false;
        }
      }
    } else if (l$files != lOther$files) {
      return false;
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$TvShowDetail$tvShow$nextEpisode
    on Query$TvShowDetail$tvShow$nextEpisode {
  CopyWith$Query$TvShowDetail$tvShow$nextEpisode<
          Query$TvShowDetail$tvShow$nextEpisode>
      get copyWith =>
          CopyWith$Query$TvShowDetail$tvShow$nextEpisode(this, (i) => i);
}

abstract class CopyWith$Query$TvShowDetail$tvShow$nextEpisode<TRes> {
  factory CopyWith$Query$TvShowDetail$tvShow$nextEpisode(
    Query$TvShowDetail$tvShow$nextEpisode instance,
    TRes Function(Query$TvShowDetail$tvShow$nextEpisode) then,
  ) = _CopyWithImpl$Query$TvShowDetail$tvShow$nextEpisode;

  factory CopyWith$Query$TvShowDetail$tvShow$nextEpisode.stub(TRes res) =
      _CopyWithStubImpl$Query$TvShowDetail$tvShow$nextEpisode;

  TRes call({
    String? id,
    int? seasonNumber,
    int? episodeNumber,
    String? title,
    String? airDate,
    List<Fragment$MediaFileFragment?>? files,
    String? $__typename,
  });
  TRes files(
    Iterable<Fragment$MediaFileFragment?>? Function(
      Iterable<
          CopyWith$Fragment$MediaFileFragment<Fragment$MediaFileFragment>?>?,
    ) _fn,
  );
}

class _CopyWithImpl$Query$TvShowDetail$tvShow$nextEpisode<TRes>
    implements CopyWith$Query$TvShowDetail$tvShow$nextEpisode<TRes> {
  _CopyWithImpl$Query$TvShowDetail$tvShow$nextEpisode(
    this._instance,
    this._then,
  );

  final Query$TvShowDetail$tvShow$nextEpisode _instance;

  final TRes Function(Query$TvShowDetail$tvShow$nextEpisode) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? seasonNumber = _undefined,
    Object? episodeNumber = _undefined,
    Object? title = _undefined,
    Object? airDate = _undefined,
    Object? files = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$TvShowDetail$tvShow$nextEpisode(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          seasonNumber: seasonNumber == _undefined || seasonNumber == null
              ? _instance.seasonNumber
              : (seasonNumber as int),
          episodeNumber: episodeNumber == _undefined || episodeNumber == null
              ? _instance.episodeNumber
              : (episodeNumber as int),
          title: title == _undefined ? _instance.title : (title as String?),
          airDate:
              airDate == _undefined ? _instance.airDate : (airDate as String?),
          files: files == _undefined
              ? _instance.files
              : (files as List<Fragment$MediaFileFragment?>?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  TRes files(
    Iterable<Fragment$MediaFileFragment?>? Function(
      Iterable<
          CopyWith$Fragment$MediaFileFragment<Fragment$MediaFileFragment>?>?,
    ) _fn,
  ) =>
      call(
        files: _fn(
          _instance.files?.map(
            (e) => e == null
                ? null
                : CopyWith$Fragment$MediaFileFragment(e, (i) => i),
          ),
        )?.toList(),
      );
}

class _CopyWithStubImpl$Query$TvShowDetail$tvShow$nextEpisode<TRes>
    implements CopyWith$Query$TvShowDetail$tvShow$nextEpisode<TRes> {
  _CopyWithStubImpl$Query$TvShowDetail$tvShow$nextEpisode(this._res);

  TRes _res;

  call({
    String? id,
    int? seasonNumber,
    int? episodeNumber,
    String? title,
    String? airDate,
    List<Fragment$MediaFileFragment?>? files,
    String? $__typename,
  }) =>
      _res;

  files(_fn) => _res;
}
