import '../fragments/artwork_fragment.graphql.dart';
import '../fragments/media_file_fragment.graphql.dart';
import '../fragments/progress_fragment.graphql.dart';
import '../schema.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Query$MovieDetail {
  factory Variables$Query$MovieDetail({required String id}) =>
      Variables$Query$MovieDetail._({r'id': id});

  Variables$Query$MovieDetail._(this._$data);

  factory Variables$Query$MovieDetail.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    final l$id = data['id'];
    result$data['id'] = (l$id as String);
    return Variables$Query$MovieDetail._(result$data);
  }

  Map<String, dynamic> _$data;

  String get id => (_$data['id'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$id = id;
    result$data['id'] = l$id;
    return result$data;
  }

  CopyWith$Variables$Query$MovieDetail<Variables$Query$MovieDetail>
      get copyWith => CopyWith$Variables$Query$MovieDetail(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Query$MovieDetail ||
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

abstract class CopyWith$Variables$Query$MovieDetail<TRes> {
  factory CopyWith$Variables$Query$MovieDetail(
    Variables$Query$MovieDetail instance,
    TRes Function(Variables$Query$MovieDetail) then,
  ) = _CopyWithImpl$Variables$Query$MovieDetail;

  factory CopyWith$Variables$Query$MovieDetail.stub(TRes res) =
      _CopyWithStubImpl$Variables$Query$MovieDetail;

  TRes call({String? id});
}

class _CopyWithImpl$Variables$Query$MovieDetail<TRes>
    implements CopyWith$Variables$Query$MovieDetail<TRes> {
  _CopyWithImpl$Variables$Query$MovieDetail(this._instance, this._then);

  final Variables$Query$MovieDetail _instance;

  final TRes Function(Variables$Query$MovieDetail) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? id = _undefined}) => _then(
        Variables$Query$MovieDetail._({
          ..._instance._$data,
          if (id != _undefined && id != null) 'id': (id as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Query$MovieDetail<TRes>
    implements CopyWith$Variables$Query$MovieDetail<TRes> {
  _CopyWithStubImpl$Variables$Query$MovieDetail(this._res);

  TRes _res;

  call({String? id}) => _res;
}

class Query$MovieDetail {
  Query$MovieDetail({this.movie, this.$__typename = 'RootQueryType'});

  factory Query$MovieDetail.fromJson(Map<String, dynamic> json) {
    final l$movie = json['movie'];
    final l$$__typename = json['__typename'];
    return Query$MovieDetail(
      movie: l$movie == null
          ? null
          : Query$MovieDetail$movie.fromJson((l$movie as Map<String, dynamic>)),
      $__typename: (l$$__typename as String),
    );
  }

  final Query$MovieDetail$movie? movie;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$movie = movie;
    _resultData['movie'] = l$movie?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$movie = movie;
    final l$$__typename = $__typename;
    return Object.hashAll([l$movie, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$MovieDetail || runtimeType != other.runtimeType) {
      return false;
    }
    final l$movie = movie;
    final lOther$movie = other.movie;
    if (l$movie != lOther$movie) {
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

extension UtilityExtension$Query$MovieDetail on Query$MovieDetail {
  CopyWith$Query$MovieDetail<Query$MovieDetail> get copyWith =>
      CopyWith$Query$MovieDetail(this, (i) => i);
}

abstract class CopyWith$Query$MovieDetail<TRes> {
  factory CopyWith$Query$MovieDetail(
    Query$MovieDetail instance,
    TRes Function(Query$MovieDetail) then,
  ) = _CopyWithImpl$Query$MovieDetail;

  factory CopyWith$Query$MovieDetail.stub(TRes res) =
      _CopyWithStubImpl$Query$MovieDetail;

  TRes call({Query$MovieDetail$movie? movie, String? $__typename});
  CopyWith$Query$MovieDetail$movie<TRes> get movie;
}

class _CopyWithImpl$Query$MovieDetail<TRes>
    implements CopyWith$Query$MovieDetail<TRes> {
  _CopyWithImpl$Query$MovieDetail(this._instance, this._then);

  final Query$MovieDetail _instance;

  final TRes Function(Query$MovieDetail) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? movie = _undefined, Object? $__typename = _undefined}) =>
      _then(
        Query$MovieDetail(
          movie: movie == _undefined
              ? _instance.movie
              : (movie as Query$MovieDetail$movie?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Query$MovieDetail$movie<TRes> get movie {
    final local$movie = _instance.movie;
    return local$movie == null
        ? CopyWith$Query$MovieDetail$movie.stub(_then(_instance))
        : CopyWith$Query$MovieDetail$movie(local$movie, (e) => call(movie: e));
  }
}

class _CopyWithStubImpl$Query$MovieDetail<TRes>
    implements CopyWith$Query$MovieDetail<TRes> {
  _CopyWithStubImpl$Query$MovieDetail(this._res);

  TRes _res;

  call({Query$MovieDetail$movie? movie, String? $__typename}) => _res;

  CopyWith$Query$MovieDetail$movie<TRes> get movie =>
      CopyWith$Query$MovieDetail$movie.stub(_res);
}

const documentNodeQueryMovieDetail = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.query,
      name: NameNode(value: 'MovieDetail'),
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
            name: NameNode(value: 'movie'),
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
                  name: NameNode(value: 'runtime'),
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
                  name: NameNode(value: 'progress'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: SelectionSetNode(
                    selections: [
                      FragmentSpreadNode(
                        name: NameNode(value: 'ProgressFragment'),
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
    fragmentDefinitionProgressFragment,
    fragmentDefinitionMediaFileFragment,
  ],
);

class Query$MovieDetail$movie {
  Query$MovieDetail$movie({
    required this.id,
    required this.title,
    this.originalTitle,
    this.year,
    this.overview,
    this.runtime,
    this.genres,
    this.contentRating,
    this.rating,
    this.tmdbId,
    this.imdbId,
    this.category,
    required this.monitored,
    required this.addedAt,
    this.artwork,
    this.progress,
    this.files,
    required this.isFavorite,
    this.$__typename = 'Movie',
  });

  factory Query$MovieDetail$movie.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$title = json['title'];
    final l$originalTitle = json['originalTitle'];
    final l$year = json['year'];
    final l$overview = json['overview'];
    final l$runtime = json['runtime'];
    final l$genres = json['genres'];
    final l$contentRating = json['contentRating'];
    final l$rating = json['rating'];
    final l$tmdbId = json['tmdbId'];
    final l$imdbId = json['imdbId'];
    final l$category = json['category'];
    final l$monitored = json['monitored'];
    final l$addedAt = json['addedAt'];
    final l$artwork = json['artwork'];
    final l$progress = json['progress'];
    final l$files = json['files'];
    final l$isFavorite = json['isFavorite'];
    final l$$__typename = json['__typename'];
    return Query$MovieDetail$movie(
      id: (l$id as String),
      title: (l$title as String),
      originalTitle: (l$originalTitle as String?),
      year: (l$year as int?),
      overview: (l$overview as String?),
      runtime: (l$runtime as int?),
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
      artwork: l$artwork == null
          ? null
          : Fragment$ArtworkFragment.fromJson(
              (l$artwork as Map<String, dynamic>),
            ),
      progress: l$progress == null
          ? null
          : Fragment$ProgressFragment.fromJson(
              (l$progress as Map<String, dynamic>),
            ),
      files: (l$files as List<dynamic>?)
          ?.map(
            (e) => e == null
                ? null
                : Fragment$MediaFileFragment.fromJson(
                    (e as Map<String, dynamic>),
                  ),
          )
          .toList(),
      isFavorite: (l$isFavorite as bool),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String title;

  final String? originalTitle;

  final int? year;

  final String? overview;

  final int? runtime;

  final List<String?>? genres;

  final String? contentRating;

  final double? rating;

  final int? tmdbId;

  final String? imdbId;

  final Enum$MediaCategory? category;

  final bool monitored;

  final String addedAt;

  final Fragment$ArtworkFragment? artwork;

  final Fragment$ProgressFragment? progress;

  final List<Fragment$MediaFileFragment?>? files;

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
    final l$runtime = runtime;
    _resultData['runtime'] = l$runtime;
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
    final l$artwork = artwork;
    _resultData['artwork'] = l$artwork?.toJson();
    final l$progress = progress;
    _resultData['progress'] = l$progress?.toJson();
    final l$files = files;
    _resultData['files'] = l$files?.map((e) => e?.toJson()).toList();
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
    final l$runtime = runtime;
    final l$genres = genres;
    final l$contentRating = contentRating;
    final l$rating = rating;
    final l$tmdbId = tmdbId;
    final l$imdbId = imdbId;
    final l$category = category;
    final l$monitored = monitored;
    final l$addedAt = addedAt;
    final l$artwork = artwork;
    final l$progress = progress;
    final l$files = files;
    final l$isFavorite = isFavorite;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$title,
      l$originalTitle,
      l$year,
      l$overview,
      l$runtime,
      l$genres == null ? null : Object.hashAll(l$genres.map((v) => v)),
      l$contentRating,
      l$rating,
      l$tmdbId,
      l$imdbId,
      l$category,
      l$monitored,
      l$addedAt,
      l$artwork,
      l$progress,
      l$files == null ? null : Object.hashAll(l$files.map((v) => v)),
      l$isFavorite,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$MovieDetail$movie || runtimeType != other.runtimeType) {
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
    final l$runtime = runtime;
    final lOther$runtime = other.runtime;
    if (l$runtime != lOther$runtime) {
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
    final l$artwork = artwork;
    final lOther$artwork = other.artwork;
    if (l$artwork != lOther$artwork) {
      return false;
    }
    final l$progress = progress;
    final lOther$progress = other.progress;
    if (l$progress != lOther$progress) {
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

extension UtilityExtension$Query$MovieDetail$movie on Query$MovieDetail$movie {
  CopyWith$Query$MovieDetail$movie<Query$MovieDetail$movie> get copyWith =>
      CopyWith$Query$MovieDetail$movie(this, (i) => i);
}

abstract class CopyWith$Query$MovieDetail$movie<TRes> {
  factory CopyWith$Query$MovieDetail$movie(
    Query$MovieDetail$movie instance,
    TRes Function(Query$MovieDetail$movie) then,
  ) = _CopyWithImpl$Query$MovieDetail$movie;

  factory CopyWith$Query$MovieDetail$movie.stub(TRes res) =
      _CopyWithStubImpl$Query$MovieDetail$movie;

  TRes call({
    String? id,
    String? title,
    String? originalTitle,
    int? year,
    String? overview,
    int? runtime,
    List<String?>? genres,
    String? contentRating,
    double? rating,
    int? tmdbId,
    String? imdbId,
    Enum$MediaCategory? category,
    bool? monitored,
    String? addedAt,
    Fragment$ArtworkFragment? artwork,
    Fragment$ProgressFragment? progress,
    List<Fragment$MediaFileFragment?>? files,
    bool? isFavorite,
    String? $__typename,
  });
  CopyWith$Fragment$ArtworkFragment<TRes> get artwork;
  CopyWith$Fragment$ProgressFragment<TRes> get progress;
  TRes files(
    Iterable<Fragment$MediaFileFragment?>? Function(
      Iterable<
          CopyWith$Fragment$MediaFileFragment<Fragment$MediaFileFragment>?>?,
    ) _fn,
  );
}

class _CopyWithImpl$Query$MovieDetail$movie<TRes>
    implements CopyWith$Query$MovieDetail$movie<TRes> {
  _CopyWithImpl$Query$MovieDetail$movie(this._instance, this._then);

  final Query$MovieDetail$movie _instance;

  final TRes Function(Query$MovieDetail$movie) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? title = _undefined,
    Object? originalTitle = _undefined,
    Object? year = _undefined,
    Object? overview = _undefined,
    Object? runtime = _undefined,
    Object? genres = _undefined,
    Object? contentRating = _undefined,
    Object? rating = _undefined,
    Object? tmdbId = _undefined,
    Object? imdbId = _undefined,
    Object? category = _undefined,
    Object? monitored = _undefined,
    Object? addedAt = _undefined,
    Object? artwork = _undefined,
    Object? progress = _undefined,
    Object? files = _undefined,
    Object? isFavorite = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$MovieDetail$movie(
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
          runtime:
              runtime == _undefined ? _instance.runtime : (runtime as int?),
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
          artwork: artwork == _undefined
              ? _instance.artwork
              : (artwork as Fragment$ArtworkFragment?),
          progress: progress == _undefined
              ? _instance.progress
              : (progress as Fragment$ProgressFragment?),
          files: files == _undefined
              ? _instance.files
              : (files as List<Fragment$MediaFileFragment?>?),
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

  CopyWith$Fragment$ProgressFragment<TRes> get progress {
    final local$progress = _instance.progress;
    return local$progress == null
        ? CopyWith$Fragment$ProgressFragment.stub(_then(_instance))
        : CopyWith$Fragment$ProgressFragment(
            local$progress,
            (e) => call(progress: e),
          );
  }

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

class _CopyWithStubImpl$Query$MovieDetail$movie<TRes>
    implements CopyWith$Query$MovieDetail$movie<TRes> {
  _CopyWithStubImpl$Query$MovieDetail$movie(this._res);

  TRes _res;

  call({
    String? id,
    String? title,
    String? originalTitle,
    int? year,
    String? overview,
    int? runtime,
    List<String?>? genres,
    String? contentRating,
    double? rating,
    int? tmdbId,
    String? imdbId,
    Enum$MediaCategory? category,
    bool? monitored,
    String? addedAt,
    Fragment$ArtworkFragment? artwork,
    Fragment$ProgressFragment? progress,
    List<Fragment$MediaFileFragment?>? files,
    bool? isFavorite,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork =>
      CopyWith$Fragment$ArtworkFragment.stub(_res);

  CopyWith$Fragment$ProgressFragment<TRes> get progress =>
      CopyWith$Fragment$ProgressFragment.stub(_res);

  files(_fn) => _res;
}
