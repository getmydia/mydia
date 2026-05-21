import '../fragments/artwork_fragment.graphql.dart';
import '../fragments/media_file_fragment.graphql.dart';
import '../fragments/progress_fragment.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Query$EpisodeDetail {
  factory Variables$Query$EpisodeDetail({required String id}) =>
      Variables$Query$EpisodeDetail._({r'id': id});

  Variables$Query$EpisodeDetail._(this._$data);

  factory Variables$Query$EpisodeDetail.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    final l$id = data['id'];
    result$data['id'] = (l$id as String);
    return Variables$Query$EpisodeDetail._(result$data);
  }

  Map<String, dynamic> _$data;

  String get id => (_$data['id'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$id = id;
    result$data['id'] = l$id;
    return result$data;
  }

  CopyWith$Variables$Query$EpisodeDetail<Variables$Query$EpisodeDetail>
      get copyWith => CopyWith$Variables$Query$EpisodeDetail(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Query$EpisodeDetail ||
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

abstract class CopyWith$Variables$Query$EpisodeDetail<TRes> {
  factory CopyWith$Variables$Query$EpisodeDetail(
    Variables$Query$EpisodeDetail instance,
    TRes Function(Variables$Query$EpisodeDetail) then,
  ) = _CopyWithImpl$Variables$Query$EpisodeDetail;

  factory CopyWith$Variables$Query$EpisodeDetail.stub(TRes res) =
      _CopyWithStubImpl$Variables$Query$EpisodeDetail;

  TRes call({String? id});
}

class _CopyWithImpl$Variables$Query$EpisodeDetail<TRes>
    implements CopyWith$Variables$Query$EpisodeDetail<TRes> {
  _CopyWithImpl$Variables$Query$EpisodeDetail(this._instance, this._then);

  final Variables$Query$EpisodeDetail _instance;

  final TRes Function(Variables$Query$EpisodeDetail) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? id = _undefined}) => _then(
        Variables$Query$EpisodeDetail._({
          ..._instance._$data,
          if (id != _undefined && id != null) 'id': (id as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Query$EpisodeDetail<TRes>
    implements CopyWith$Variables$Query$EpisodeDetail<TRes> {
  _CopyWithStubImpl$Variables$Query$EpisodeDetail(this._res);

  TRes _res;

  call({String? id}) => _res;
}

class Query$EpisodeDetail {
  Query$EpisodeDetail({this.episode, this.$__typename = 'RootQueryType'});

  factory Query$EpisodeDetail.fromJson(Map<String, dynamic> json) {
    final l$episode = json['episode'];
    final l$$__typename = json['__typename'];
    return Query$EpisodeDetail(
      episode: l$episode == null
          ? null
          : Query$EpisodeDetail$episode.fromJson(
              (l$episode as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Query$EpisodeDetail$episode? episode;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$episode = episode;
    _resultData['episode'] = l$episode?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$episode = episode;
    final l$$__typename = $__typename;
    return Object.hashAll([l$episode, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$EpisodeDetail || runtimeType != other.runtimeType) {
      return false;
    }
    final l$episode = episode;
    final lOther$episode = other.episode;
    if (l$episode != lOther$episode) {
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

extension UtilityExtension$Query$EpisodeDetail on Query$EpisodeDetail {
  CopyWith$Query$EpisodeDetail<Query$EpisodeDetail> get copyWith =>
      CopyWith$Query$EpisodeDetail(this, (i) => i);
}

abstract class CopyWith$Query$EpisodeDetail<TRes> {
  factory CopyWith$Query$EpisodeDetail(
    Query$EpisodeDetail instance,
    TRes Function(Query$EpisodeDetail) then,
  ) = _CopyWithImpl$Query$EpisodeDetail;

  factory CopyWith$Query$EpisodeDetail.stub(TRes res) =
      _CopyWithStubImpl$Query$EpisodeDetail;

  TRes call({Query$EpisodeDetail$episode? episode, String? $__typename});
  CopyWith$Query$EpisodeDetail$episode<TRes> get episode;
}

class _CopyWithImpl$Query$EpisodeDetail<TRes>
    implements CopyWith$Query$EpisodeDetail<TRes> {
  _CopyWithImpl$Query$EpisodeDetail(this._instance, this._then);

  final Query$EpisodeDetail _instance;

  final TRes Function(Query$EpisodeDetail) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? episode = _undefined, Object? $__typename = _undefined}) =>
      _then(
        Query$EpisodeDetail(
          episode: episode == _undefined
              ? _instance.episode
              : (episode as Query$EpisodeDetail$episode?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Query$EpisodeDetail$episode<TRes> get episode {
    final local$episode = _instance.episode;
    return local$episode == null
        ? CopyWith$Query$EpisodeDetail$episode.stub(_then(_instance))
        : CopyWith$Query$EpisodeDetail$episode(
            local$episode,
            (e) => call(episode: e),
          );
  }
}

class _CopyWithStubImpl$Query$EpisodeDetail<TRes>
    implements CopyWith$Query$EpisodeDetail<TRes> {
  _CopyWithStubImpl$Query$EpisodeDetail(this._res);

  TRes _res;

  call({Query$EpisodeDetail$episode? episode, String? $__typename}) => _res;

  CopyWith$Query$EpisodeDetail$episode<TRes> get episode =>
      CopyWith$Query$EpisodeDetail$episode.stub(_res);
}

const documentNodeQueryEpisodeDetail = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.query,
      name: NameNode(value: 'EpisodeDetail'),
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
            name: NameNode(value: 'episode'),
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
                  name: NameNode(value: 'overview'),
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
                  name: NameNode(value: 'runtime'),
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
                  name: NameNode(value: 'thumbnailUrl'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'hasFile'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
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
                  name: NameNode(value: 'show'),
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
                        name: NameNode(value: 'title'),
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
            name: NameNode(value: '__typename'),
            alias: null,
            arguments: [],
            directives: [],
            selectionSet: null,
          ),
        ],
      ),
    ),
    fragmentDefinitionProgressFragment,
    fragmentDefinitionMediaFileFragment,
    fragmentDefinitionArtworkFragment,
  ],
);

class Query$EpisodeDetail$episode {
  Query$EpisodeDetail$episode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    this.title,
    this.overview,
    this.airDate,
    this.runtime,
    required this.monitored,
    this.thumbnailUrl,
    required this.hasFile,
    this.progress,
    this.files,
    this.$show,
    this.$__typename = 'Episode',
  });

  factory Query$EpisodeDetail$episode.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$seasonNumber = json['seasonNumber'];
    final l$episodeNumber = json['episodeNumber'];
    final l$title = json['title'];
    final l$overview = json['overview'];
    final l$airDate = json['airDate'];
    final l$runtime = json['runtime'];
    final l$monitored = json['monitored'];
    final l$thumbnailUrl = json['thumbnailUrl'];
    final l$hasFile = json['hasFile'];
    final l$progress = json['progress'];
    final l$files = json['files'];
    final l$$show = json['show'];
    final l$$__typename = json['__typename'];
    return Query$EpisodeDetail$episode(
      id: (l$id as String),
      seasonNumber: (l$seasonNumber as int),
      episodeNumber: (l$episodeNumber as int),
      title: (l$title as String?),
      overview: (l$overview as String?),
      airDate: (l$airDate as String?),
      runtime: (l$runtime as int?),
      monitored: (l$monitored as bool),
      thumbnailUrl: (l$thumbnailUrl as String?),
      hasFile: (l$hasFile as bool),
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
      $show: l$$show == null
          ? null
          : Query$EpisodeDetail$episode$show.fromJson(
              (l$$show as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final int seasonNumber;

  final int episodeNumber;

  final String? title;

  final String? overview;

  final String? airDate;

  final int? runtime;

  final bool monitored;

  final String? thumbnailUrl;

  final bool hasFile;

  final Fragment$ProgressFragment? progress;

  final List<Fragment$MediaFileFragment?>? files;

  final Query$EpisodeDetail$episode$show? $show;

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
    final l$overview = overview;
    _resultData['overview'] = l$overview;
    final l$airDate = airDate;
    _resultData['airDate'] = l$airDate;
    final l$runtime = runtime;
    _resultData['runtime'] = l$runtime;
    final l$monitored = monitored;
    _resultData['monitored'] = l$monitored;
    final l$thumbnailUrl = thumbnailUrl;
    _resultData['thumbnailUrl'] = l$thumbnailUrl;
    final l$hasFile = hasFile;
    _resultData['hasFile'] = l$hasFile;
    final l$progress = progress;
    _resultData['progress'] = l$progress?.toJson();
    final l$files = files;
    _resultData['files'] = l$files?.map((e) => e?.toJson()).toList();
    final l$$show = $show;
    _resultData['show'] = l$$show?.toJson();
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
    final l$overview = overview;
    final l$airDate = airDate;
    final l$runtime = runtime;
    final l$monitored = monitored;
    final l$thumbnailUrl = thumbnailUrl;
    final l$hasFile = hasFile;
    final l$progress = progress;
    final l$files = files;
    final l$$show = $show;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$seasonNumber,
      l$episodeNumber,
      l$title,
      l$overview,
      l$airDate,
      l$runtime,
      l$monitored,
      l$thumbnailUrl,
      l$hasFile,
      l$progress,
      l$files == null ? null : Object.hashAll(l$files.map((v) => v)),
      l$$show,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$EpisodeDetail$episode ||
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
    final l$overview = overview;
    final lOther$overview = other.overview;
    if (l$overview != lOther$overview) {
      return false;
    }
    final l$airDate = airDate;
    final lOther$airDate = other.airDate;
    if (l$airDate != lOther$airDate) {
      return false;
    }
    final l$runtime = runtime;
    final lOther$runtime = other.runtime;
    if (l$runtime != lOther$runtime) {
      return false;
    }
    final l$monitored = monitored;
    final lOther$monitored = other.monitored;
    if (l$monitored != lOther$monitored) {
      return false;
    }
    final l$thumbnailUrl = thumbnailUrl;
    final lOther$thumbnailUrl = other.thumbnailUrl;
    if (l$thumbnailUrl != lOther$thumbnailUrl) {
      return false;
    }
    final l$hasFile = hasFile;
    final lOther$hasFile = other.hasFile;
    if (l$hasFile != lOther$hasFile) {
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
    final l$$show = $show;
    final lOther$$show = other.$show;
    if (l$$show != lOther$$show) {
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

extension UtilityExtension$Query$EpisodeDetail$episode
    on Query$EpisodeDetail$episode {
  CopyWith$Query$EpisodeDetail$episode<Query$EpisodeDetail$episode>
      get copyWith => CopyWith$Query$EpisodeDetail$episode(this, (i) => i);
}

abstract class CopyWith$Query$EpisodeDetail$episode<TRes> {
  factory CopyWith$Query$EpisodeDetail$episode(
    Query$EpisodeDetail$episode instance,
    TRes Function(Query$EpisodeDetail$episode) then,
  ) = _CopyWithImpl$Query$EpisodeDetail$episode;

  factory CopyWith$Query$EpisodeDetail$episode.stub(TRes res) =
      _CopyWithStubImpl$Query$EpisodeDetail$episode;

  TRes call({
    String? id,
    int? seasonNumber,
    int? episodeNumber,
    String? title,
    String? overview,
    String? airDate,
    int? runtime,
    bool? monitored,
    String? thumbnailUrl,
    bool? hasFile,
    Fragment$ProgressFragment? progress,
    List<Fragment$MediaFileFragment?>? files,
    Query$EpisodeDetail$episode$show? $show,
    String? $__typename,
  });
  CopyWith$Fragment$ProgressFragment<TRes> get progress;
  TRes files(
    Iterable<Fragment$MediaFileFragment?>? Function(
      Iterable<
          CopyWith$Fragment$MediaFileFragment<Fragment$MediaFileFragment>?>?,
    ) _fn,
  );
  CopyWith$Query$EpisodeDetail$episode$show<TRes> get $show;
}

class _CopyWithImpl$Query$EpisodeDetail$episode<TRes>
    implements CopyWith$Query$EpisodeDetail$episode<TRes> {
  _CopyWithImpl$Query$EpisodeDetail$episode(this._instance, this._then);

  final Query$EpisodeDetail$episode _instance;

  final TRes Function(Query$EpisodeDetail$episode) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? seasonNumber = _undefined,
    Object? episodeNumber = _undefined,
    Object? title = _undefined,
    Object? overview = _undefined,
    Object? airDate = _undefined,
    Object? runtime = _undefined,
    Object? monitored = _undefined,
    Object? thumbnailUrl = _undefined,
    Object? hasFile = _undefined,
    Object? progress = _undefined,
    Object? files = _undefined,
    Object? $show = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$EpisodeDetail$episode(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          seasonNumber: seasonNumber == _undefined || seasonNumber == null
              ? _instance.seasonNumber
              : (seasonNumber as int),
          episodeNumber: episodeNumber == _undefined || episodeNumber == null
              ? _instance.episodeNumber
              : (episodeNumber as int),
          title: title == _undefined ? _instance.title : (title as String?),
          overview: overview == _undefined
              ? _instance.overview
              : (overview as String?),
          airDate:
              airDate == _undefined ? _instance.airDate : (airDate as String?),
          runtime:
              runtime == _undefined ? _instance.runtime : (runtime as int?),
          monitored: monitored == _undefined || monitored == null
              ? _instance.monitored
              : (monitored as bool),
          thumbnailUrl: thumbnailUrl == _undefined
              ? _instance.thumbnailUrl
              : (thumbnailUrl as String?),
          hasFile: hasFile == _undefined || hasFile == null
              ? _instance.hasFile
              : (hasFile as bool),
          progress: progress == _undefined
              ? _instance.progress
              : (progress as Fragment$ProgressFragment?),
          files: files == _undefined
              ? _instance.files
              : (files as List<Fragment$MediaFileFragment?>?),
          $show: $show == _undefined
              ? _instance.$show
              : ($show as Query$EpisodeDetail$episode$show?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

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

  CopyWith$Query$EpisodeDetail$episode$show<TRes> get $show {
    final local$$show = _instance.$show;
    return local$$show == null
        ? CopyWith$Query$EpisodeDetail$episode$show.stub(_then(_instance))
        : CopyWith$Query$EpisodeDetail$episode$show(
            local$$show,
            (e) => call($show: e),
          );
  }
}

class _CopyWithStubImpl$Query$EpisodeDetail$episode<TRes>
    implements CopyWith$Query$EpisodeDetail$episode<TRes> {
  _CopyWithStubImpl$Query$EpisodeDetail$episode(this._res);

  TRes _res;

  call({
    String? id,
    int? seasonNumber,
    int? episodeNumber,
    String? title,
    String? overview,
    String? airDate,
    int? runtime,
    bool? monitored,
    String? thumbnailUrl,
    bool? hasFile,
    Fragment$ProgressFragment? progress,
    List<Fragment$MediaFileFragment?>? files,
    Query$EpisodeDetail$episode$show? $show,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ProgressFragment<TRes> get progress =>
      CopyWith$Fragment$ProgressFragment.stub(_res);

  files(_fn) => _res;

  CopyWith$Query$EpisodeDetail$episode$show<TRes> get $show =>
      CopyWith$Query$EpisodeDetail$episode$show.stub(_res);
}

class Query$EpisodeDetail$episode$show {
  Query$EpisodeDetail$episode$show({
    required this.id,
    required this.title,
    this.artwork,
    this.$__typename = 'TvShow',
  });

  factory Query$EpisodeDetail$episode$show.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$title = json['title'];
    final l$artwork = json['artwork'];
    final l$$__typename = json['__typename'];
    return Query$EpisodeDetail$episode$show(
      id: (l$id as String),
      title: (l$title as String),
      artwork: l$artwork == null
          ? null
          : Fragment$ArtworkFragment.fromJson(
              (l$artwork as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String title;

  final Fragment$ArtworkFragment? artwork;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$artwork = artwork;
    _resultData['artwork'] = l$artwork?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$title = title;
    final l$artwork = artwork;
    final l$$__typename = $__typename;
    return Object.hashAll([l$id, l$title, l$artwork, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$EpisodeDetail$episode$show ||
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
    final l$artwork = artwork;
    final lOther$artwork = other.artwork;
    if (l$artwork != lOther$artwork) {
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

extension UtilityExtension$Query$EpisodeDetail$episode$show
    on Query$EpisodeDetail$episode$show {
  CopyWith$Query$EpisodeDetail$episode$show<Query$EpisodeDetail$episode$show>
      get copyWith => CopyWith$Query$EpisodeDetail$episode$show(this, (i) => i);
}

abstract class CopyWith$Query$EpisodeDetail$episode$show<TRes> {
  factory CopyWith$Query$EpisodeDetail$episode$show(
    Query$EpisodeDetail$episode$show instance,
    TRes Function(Query$EpisodeDetail$episode$show) then,
  ) = _CopyWithImpl$Query$EpisodeDetail$episode$show;

  factory CopyWith$Query$EpisodeDetail$episode$show.stub(TRes res) =
      _CopyWithStubImpl$Query$EpisodeDetail$episode$show;

  TRes call({
    String? id,
    String? title,
    Fragment$ArtworkFragment? artwork,
    String? $__typename,
  });
  CopyWith$Fragment$ArtworkFragment<TRes> get artwork;
}

class _CopyWithImpl$Query$EpisodeDetail$episode$show<TRes>
    implements CopyWith$Query$EpisodeDetail$episode$show<TRes> {
  _CopyWithImpl$Query$EpisodeDetail$episode$show(this._instance, this._then);

  final Query$EpisodeDetail$episode$show _instance;

  final TRes Function(Query$EpisodeDetail$episode$show) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? title = _undefined,
    Object? artwork = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$EpisodeDetail$episode$show(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          title: title == _undefined || title == null
              ? _instance.title
              : (title as String),
          artwork: artwork == _undefined
              ? _instance.artwork
              : (artwork as Fragment$ArtworkFragment?),
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
}

class _CopyWithStubImpl$Query$EpisodeDetail$episode$show<TRes>
    implements CopyWith$Query$EpisodeDetail$episode$show<TRes> {
  _CopyWithStubImpl$Query$EpisodeDetail$episode$show(this._res);

  TRes _res;

  call({
    String? id,
    String? title,
    Fragment$ArtworkFragment? artwork,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork =>
      CopyWith$Fragment$ArtworkFragment.stub(_res);
}
