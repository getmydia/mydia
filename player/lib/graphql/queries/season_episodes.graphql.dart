import '../fragments/media_file_fragment.graphql.dart';
import '../fragments/progress_fragment.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Query$SeasonEpisodes {
  factory Variables$Query$SeasonEpisodes({
    required String showId,
    required int seasonNumber,
  }) =>
      Variables$Query$SeasonEpisodes._({
        r'showId': showId,
        r'seasonNumber': seasonNumber,
      });

  Variables$Query$SeasonEpisodes._(this._$data);

  factory Variables$Query$SeasonEpisodes.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    final l$showId = data['showId'];
    result$data['showId'] = (l$showId as String);
    final l$seasonNumber = data['seasonNumber'];
    result$data['seasonNumber'] = (l$seasonNumber as int);
    return Variables$Query$SeasonEpisodes._(result$data);
  }

  Map<String, dynamic> _$data;

  String get showId => (_$data['showId'] as String);

  int get seasonNumber => (_$data['seasonNumber'] as int);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$showId = showId;
    result$data['showId'] = l$showId;
    final l$seasonNumber = seasonNumber;
    result$data['seasonNumber'] = l$seasonNumber;
    return result$data;
  }

  CopyWith$Variables$Query$SeasonEpisodes<Variables$Query$SeasonEpisodes>
      get copyWith => CopyWith$Variables$Query$SeasonEpisodes(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Query$SeasonEpisodes ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$showId = showId;
    final lOther$showId = other.showId;
    if (l$showId != lOther$showId) {
      return false;
    }
    final l$seasonNumber = seasonNumber;
    final lOther$seasonNumber = other.seasonNumber;
    if (l$seasonNumber != lOther$seasonNumber) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$showId = showId;
    final l$seasonNumber = seasonNumber;
    return Object.hashAll([l$showId, l$seasonNumber]);
  }
}

abstract class CopyWith$Variables$Query$SeasonEpisodes<TRes> {
  factory CopyWith$Variables$Query$SeasonEpisodes(
    Variables$Query$SeasonEpisodes instance,
    TRes Function(Variables$Query$SeasonEpisodes) then,
  ) = _CopyWithImpl$Variables$Query$SeasonEpisodes;

  factory CopyWith$Variables$Query$SeasonEpisodes.stub(TRes res) =
      _CopyWithStubImpl$Variables$Query$SeasonEpisodes;

  TRes call({String? showId, int? seasonNumber});
}

class _CopyWithImpl$Variables$Query$SeasonEpisodes<TRes>
    implements CopyWith$Variables$Query$SeasonEpisodes<TRes> {
  _CopyWithImpl$Variables$Query$SeasonEpisodes(this._instance, this._then);

  final Variables$Query$SeasonEpisodes _instance;

  final TRes Function(Variables$Query$SeasonEpisodes) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? showId = _undefined, Object? seasonNumber = _undefined}) =>
      _then(
        Variables$Query$SeasonEpisodes._({
          ..._instance._$data,
          if (showId != _undefined && showId != null)
            'showId': (showId as String),
          if (seasonNumber != _undefined && seasonNumber != null)
            'seasonNumber': (seasonNumber as int),
        }),
      );
}

class _CopyWithStubImpl$Variables$Query$SeasonEpisodes<TRes>
    implements CopyWith$Variables$Query$SeasonEpisodes<TRes> {
  _CopyWithStubImpl$Variables$Query$SeasonEpisodes(this._res);

  TRes _res;

  call({String? showId, int? seasonNumber}) => _res;
}

class Query$SeasonEpisodes {
  Query$SeasonEpisodes({
    this.seasonEpisodes,
    this.$__typename = 'RootQueryType',
  });

  factory Query$SeasonEpisodes.fromJson(Map<String, dynamic> json) {
    final l$seasonEpisodes = json['seasonEpisodes'];
    final l$$__typename = json['__typename'];
    return Query$SeasonEpisodes(
      seasonEpisodes: (l$seasonEpisodes as List<dynamic>?)
          ?.map(
            (e) => e == null
                ? null
                : Query$SeasonEpisodes$seasonEpisodes.fromJson(
                    (e as Map<String, dynamic>),
                  ),
          )
          .toList(),
      $__typename: (l$$__typename as String),
    );
  }

  final List<Query$SeasonEpisodes$seasonEpisodes?>? seasonEpisodes;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$seasonEpisodes = seasonEpisodes;
    _resultData['seasonEpisodes'] =
        l$seasonEpisodes?.map((e) => e?.toJson()).toList();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$seasonEpisodes = seasonEpisodes;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$seasonEpisodes == null
          ? null
          : Object.hashAll(l$seasonEpisodes.map((v) => v)),
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$SeasonEpisodes || runtimeType != other.runtimeType) {
      return false;
    }
    final l$seasonEpisodes = seasonEpisodes;
    final lOther$seasonEpisodes = other.seasonEpisodes;
    if (l$seasonEpisodes != null && lOther$seasonEpisodes != null) {
      if (l$seasonEpisodes.length != lOther$seasonEpisodes.length) {
        return false;
      }
      for (int i = 0; i < l$seasonEpisodes.length; i++) {
        final l$seasonEpisodes$entry = l$seasonEpisodes[i];
        final lOther$seasonEpisodes$entry = lOther$seasonEpisodes[i];
        if (l$seasonEpisodes$entry != lOther$seasonEpisodes$entry) {
          return false;
        }
      }
    } else if (l$seasonEpisodes != lOther$seasonEpisodes) {
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

extension UtilityExtension$Query$SeasonEpisodes on Query$SeasonEpisodes {
  CopyWith$Query$SeasonEpisodes<Query$SeasonEpisodes> get copyWith =>
      CopyWith$Query$SeasonEpisodes(this, (i) => i);
}

abstract class CopyWith$Query$SeasonEpisodes<TRes> {
  factory CopyWith$Query$SeasonEpisodes(
    Query$SeasonEpisodes instance,
    TRes Function(Query$SeasonEpisodes) then,
  ) = _CopyWithImpl$Query$SeasonEpisodes;

  factory CopyWith$Query$SeasonEpisodes.stub(TRes res) =
      _CopyWithStubImpl$Query$SeasonEpisodes;

  TRes call({
    List<Query$SeasonEpisodes$seasonEpisodes?>? seasonEpisodes,
    String? $__typename,
  });
  TRes seasonEpisodes(
    Iterable<Query$SeasonEpisodes$seasonEpisodes?>? Function(
      Iterable<
          CopyWith$Query$SeasonEpisodes$seasonEpisodes<
              Query$SeasonEpisodes$seasonEpisodes>?>?,
    ) _fn,
  );
}

class _CopyWithImpl$Query$SeasonEpisodes<TRes>
    implements CopyWith$Query$SeasonEpisodes<TRes> {
  _CopyWithImpl$Query$SeasonEpisodes(this._instance, this._then);

  final Query$SeasonEpisodes _instance;

  final TRes Function(Query$SeasonEpisodes) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? seasonEpisodes = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$SeasonEpisodes(
          seasonEpisodes: seasonEpisodes == _undefined
              ? _instance.seasonEpisodes
              : (seasonEpisodes as List<Query$SeasonEpisodes$seasonEpisodes?>?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  TRes seasonEpisodes(
    Iterable<Query$SeasonEpisodes$seasonEpisodes?>? Function(
      Iterable<
          CopyWith$Query$SeasonEpisodes$seasonEpisodes<
              Query$SeasonEpisodes$seasonEpisodes>?>?,
    ) _fn,
  ) =>
      call(
        seasonEpisodes: _fn(
          _instance.seasonEpisodes?.map(
            (e) => e == null
                ? null
                : CopyWith$Query$SeasonEpisodes$seasonEpisodes(e, (i) => i),
          ),
        )?.toList(),
      );
}

class _CopyWithStubImpl$Query$SeasonEpisodes<TRes>
    implements CopyWith$Query$SeasonEpisodes<TRes> {
  _CopyWithStubImpl$Query$SeasonEpisodes(this._res);

  TRes _res;

  call({
    List<Query$SeasonEpisodes$seasonEpisodes?>? seasonEpisodes,
    String? $__typename,
  }) =>
      _res;

  seasonEpisodes(_fn) => _res;
}

const documentNodeQuerySeasonEpisodes = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.query,
      name: NameNode(value: 'SeasonEpisodes'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'showId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'seasonNumber')),
          type: NamedTypeNode(name: NameNode(value: 'Int'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'seasonEpisodes'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'showId'),
                value: VariableNode(name: NameNode(value: 'showId')),
              ),
              ArgumentNode(
                name: NameNode(value: 'seasonNumber'),
                value: VariableNode(name: NameNode(value: 'seasonNumber')),
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
  ],
);

class Query$SeasonEpisodes$seasonEpisodes {
  Query$SeasonEpisodes$seasonEpisodes({
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
    this.$__typename = 'Episode',
  });

  factory Query$SeasonEpisodes$seasonEpisodes.fromJson(
    Map<String, dynamic> json,
  ) {
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
    final l$$__typename = json['__typename'];
    return Query$SeasonEpisodes$seasonEpisodes(
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
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$SeasonEpisodes$seasonEpisodes ||
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
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$SeasonEpisodes$seasonEpisodes
    on Query$SeasonEpisodes$seasonEpisodes {
  CopyWith$Query$SeasonEpisodes$seasonEpisodes<
          Query$SeasonEpisodes$seasonEpisodes>
      get copyWith =>
          CopyWith$Query$SeasonEpisodes$seasonEpisodes(this, (i) => i);
}

abstract class CopyWith$Query$SeasonEpisodes$seasonEpisodes<TRes> {
  factory CopyWith$Query$SeasonEpisodes$seasonEpisodes(
    Query$SeasonEpisodes$seasonEpisodes instance,
    TRes Function(Query$SeasonEpisodes$seasonEpisodes) then,
  ) = _CopyWithImpl$Query$SeasonEpisodes$seasonEpisodes;

  factory CopyWith$Query$SeasonEpisodes$seasonEpisodes.stub(TRes res) =
      _CopyWithStubImpl$Query$SeasonEpisodes$seasonEpisodes;

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
    String? $__typename,
  });
  CopyWith$Fragment$ProgressFragment<TRes> get progress;
  TRes files(
    Iterable<Fragment$MediaFileFragment?>? Function(
      Iterable<
          CopyWith$Fragment$MediaFileFragment<Fragment$MediaFileFragment>?>?,
    ) _fn,
  );
}

class _CopyWithImpl$Query$SeasonEpisodes$seasonEpisodes<TRes>
    implements CopyWith$Query$SeasonEpisodes$seasonEpisodes<TRes> {
  _CopyWithImpl$Query$SeasonEpisodes$seasonEpisodes(this._instance, this._then);

  final Query$SeasonEpisodes$seasonEpisodes _instance;

  final TRes Function(Query$SeasonEpisodes$seasonEpisodes) _then;

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
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$SeasonEpisodes$seasonEpisodes(
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
}

class _CopyWithStubImpl$Query$SeasonEpisodes$seasonEpisodes<TRes>
    implements CopyWith$Query$SeasonEpisodes$seasonEpisodes<TRes> {
  _CopyWithStubImpl$Query$SeasonEpisodes$seasonEpisodes(this._res);

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
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ProgressFragment<TRes> get progress =>
      CopyWith$Fragment$ProgressFragment.stub(_res);

  files(_fn) => _res;
}
