import 'package:gql/ast.dart';

class Variables$Query$TorrentCandidates {
  factory Variables$Query$TorrentCandidates({
    required String contentType,
    required String id,
  }) => Variables$Query$TorrentCandidates._({
    r'contentType': contentType,
    r'id': id,
  });

  Variables$Query$TorrentCandidates._(this._$data);

  factory Variables$Query$TorrentCandidates.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$contentType = data['contentType'];
    result$data['contentType'] = (l$contentType as String);
    final l$id = data['id'];
    result$data['id'] = (l$id as String);
    return Variables$Query$TorrentCandidates._(result$data);
  }

  Map<String, dynamic> _$data;

  String get contentType => (_$data['contentType'] as String);

  String get id => (_$data['id'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$contentType = contentType;
    result$data['contentType'] = l$contentType;
    final l$id = id;
    result$data['id'] = l$id;
    return result$data;
  }

  CopyWith$Variables$Query$TorrentCandidates<Variables$Query$TorrentCandidates>
  get copyWith => CopyWith$Variables$Query$TorrentCandidates(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Query$TorrentCandidates ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$contentType = contentType;
    final lOther$contentType = other.contentType;
    if (l$contentType != lOther$contentType) {
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
    final l$contentType = contentType;
    final l$id = id;
    return Object.hashAll([l$contentType, l$id]);
  }
}

abstract class CopyWith$Variables$Query$TorrentCandidates<TRes> {
  factory CopyWith$Variables$Query$TorrentCandidates(
    Variables$Query$TorrentCandidates instance,
    TRes Function(Variables$Query$TorrentCandidates) then,
  ) = _CopyWithImpl$Variables$Query$TorrentCandidates;

  factory CopyWith$Variables$Query$TorrentCandidates.stub(TRes res) =
      _CopyWithStubImpl$Variables$Query$TorrentCandidates;

  TRes call({String? contentType, String? id});
}

class _CopyWithImpl$Variables$Query$TorrentCandidates<TRes>
    implements CopyWith$Variables$Query$TorrentCandidates<TRes> {
  _CopyWithImpl$Variables$Query$TorrentCandidates(this._instance, this._then);

  final Variables$Query$TorrentCandidates _instance;

  final TRes Function(Variables$Query$TorrentCandidates) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? contentType = _undefined, Object? id = _undefined}) =>
      _then(
        Variables$Query$TorrentCandidates._({
          ..._instance._$data,
          if (contentType != _undefined && contentType != null)
            'contentType': (contentType as String),
          if (id != _undefined && id != null) 'id': (id as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Query$TorrentCandidates<TRes>
    implements CopyWith$Variables$Query$TorrentCandidates<TRes> {
  _CopyWithStubImpl$Variables$Query$TorrentCandidates(this._res);

  TRes _res;

  call({String? contentType, String? id}) => _res;
}

class Query$TorrentCandidates {
  Query$TorrentCandidates({
    this.torrentCandidates,
    this.$__typename = 'RootQueryType',
  });

  factory Query$TorrentCandidates.fromJson(Map<String, dynamic> json) {
    final l$torrentCandidates = json['torrentCandidates'];
    final l$$__typename = json['__typename'];
    return Query$TorrentCandidates(
      torrentCandidates: (l$torrentCandidates as List<dynamic>?)
          ?.map(
            (e) => e == null
                ? null
                : Query$TorrentCandidates$torrentCandidates.fromJson(
                    (e as Map<String, dynamic>),
                  ),
          )
          .toList(),
      $__typename: (l$$__typename as String),
    );
  }

  final List<Query$TorrentCandidates$torrentCandidates?>? torrentCandidates;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$torrentCandidates = torrentCandidates;
    _resultData['torrentCandidates'] = l$torrentCandidates
        ?.map((e) => e?.toJson())
        .toList();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$torrentCandidates = torrentCandidates;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$torrentCandidates == null
          ? null
          : Object.hashAll(l$torrentCandidates.map((v) => v)),
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$TorrentCandidates || runtimeType != other.runtimeType) {
      return false;
    }
    final l$torrentCandidates = torrentCandidates;
    final lOther$torrentCandidates = other.torrentCandidates;
    if (l$torrentCandidates != null && lOther$torrentCandidates != null) {
      if (l$torrentCandidates.length != lOther$torrentCandidates.length) {
        return false;
      }
      for (int i = 0; i < l$torrentCandidates.length; i++) {
        final l$torrentCandidates$entry = l$torrentCandidates[i];
        final lOther$torrentCandidates$entry = lOther$torrentCandidates[i];
        if (l$torrentCandidates$entry != lOther$torrentCandidates$entry) {
          return false;
        }
      }
    } else if (l$torrentCandidates != lOther$torrentCandidates) {
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

extension UtilityExtension$Query$TorrentCandidates on Query$TorrentCandidates {
  CopyWith$Query$TorrentCandidates<Query$TorrentCandidates> get copyWith =>
      CopyWith$Query$TorrentCandidates(this, (i) => i);
}

abstract class CopyWith$Query$TorrentCandidates<TRes> {
  factory CopyWith$Query$TorrentCandidates(
    Query$TorrentCandidates instance,
    TRes Function(Query$TorrentCandidates) then,
  ) = _CopyWithImpl$Query$TorrentCandidates;

  factory CopyWith$Query$TorrentCandidates.stub(TRes res) =
      _CopyWithStubImpl$Query$TorrentCandidates;

  TRes call({
    List<Query$TorrentCandidates$torrentCandidates?>? torrentCandidates,
    String? $__typename,
  });
  TRes torrentCandidates(
    Iterable<Query$TorrentCandidates$torrentCandidates?>? Function(
      Iterable<
        CopyWith$Query$TorrentCandidates$torrentCandidates<
          Query$TorrentCandidates$torrentCandidates
        >?
      >?,
    )
    _fn,
  );
}

class _CopyWithImpl$Query$TorrentCandidates<TRes>
    implements CopyWith$Query$TorrentCandidates<TRes> {
  _CopyWithImpl$Query$TorrentCandidates(this._instance, this._then);

  final Query$TorrentCandidates _instance;

  final TRes Function(Query$TorrentCandidates) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? torrentCandidates = _undefined,
    Object? $__typename = _undefined,
  }) => _then(
    Query$TorrentCandidates(
      torrentCandidates: torrentCandidates == _undefined
          ? _instance.torrentCandidates
          : (torrentCandidates
                as List<Query$TorrentCandidates$torrentCandidates?>?),
      $__typename: $__typename == _undefined || $__typename == null
          ? _instance.$__typename
          : ($__typename as String),
    ),
  );

  TRes torrentCandidates(
    Iterable<Query$TorrentCandidates$torrentCandidates?>? Function(
      Iterable<
        CopyWith$Query$TorrentCandidates$torrentCandidates<
          Query$TorrentCandidates$torrentCandidates
        >?
      >?,
    )
    _fn,
  ) => call(
    torrentCandidates: _fn(
      _instance.torrentCandidates?.map(
        (e) => e == null
            ? null
            : CopyWith$Query$TorrentCandidates$torrentCandidates(e, (i) => i),
      ),
    )?.toList(),
  );
}

class _CopyWithStubImpl$Query$TorrentCandidates<TRes>
    implements CopyWith$Query$TorrentCandidates<TRes> {
  _CopyWithStubImpl$Query$TorrentCandidates(this._res);

  TRes _res;

  call({
    List<Query$TorrentCandidates$torrentCandidates?>? torrentCandidates,
    String? $__typename,
  }) => _res;

  torrentCandidates(_fn) => _res;
}

const documentNodeQueryTorrentCandidates = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.query,
      name: NameNode(value: 'TorrentCandidates'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'contentType')),
          type: NamedTypeNode(name: NameNode(value: 'String'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
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
            name: NameNode(value: 'torrentCandidates'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'contentType'),
                value: VariableNode(name: NameNode(value: 'contentType')),
              ),
              ArgumentNode(
                name: NameNode(value: 'id'),
                value: VariableNode(name: NameNode(value: 'id')),
              ),
            ],
            directives: [],
            selectionSet: SelectionSetNode(
              selections: [
                FieldNode(
                  name: NameNode(value: 'title'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'size'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'seeders'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'leechers'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'magnetLink'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'indexer'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'quality'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'healthScore'),
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
  ],
);

class Query$TorrentCandidates$torrentCandidates {
  Query$TorrentCandidates$torrentCandidates({
    required this.title,
    required this.size,
    this.seeders,
    this.leechers,
    required this.magnetLink,
    required this.indexer,
    this.quality,
    required this.healthScore,
    this.$__typename = 'TorrentCandidate',
  });

  factory Query$TorrentCandidates$torrentCandidates.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$title = json['title'];
    final l$size = json['size'];
    final l$seeders = json['seeders'];
    final l$leechers = json['leechers'];
    final l$magnetLink = json['magnetLink'];
    final l$indexer = json['indexer'];
    final l$quality = json['quality'];
    final l$healthScore = json['healthScore'];
    final l$$__typename = json['__typename'];
    return Query$TorrentCandidates$torrentCandidates(
      title: (l$title as String),
      size: (l$size as int),
      seeders: (l$seeders as int?),
      leechers: (l$leechers as int?),
      magnetLink: (l$magnetLink as String),
      indexer: (l$indexer as String),
      quality: (l$quality as String?),
      healthScore: (l$healthScore as num).toDouble(),
      $__typename: (l$$__typename as String),
    );
  }

  final String title;

  final int size;

  final int? seeders;

  final int? leechers;

  final String magnetLink;

  final String indexer;

  final String? quality;

  final double healthScore;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$title = title;
    _resultData['title'] = l$title;
    final l$size = size;
    _resultData['size'] = l$size;
    final l$seeders = seeders;
    _resultData['seeders'] = l$seeders;
    final l$leechers = leechers;
    _resultData['leechers'] = l$leechers;
    final l$magnetLink = magnetLink;
    _resultData['magnetLink'] = l$magnetLink;
    final l$indexer = indexer;
    _resultData['indexer'] = l$indexer;
    final l$quality = quality;
    _resultData['quality'] = l$quality;
    final l$healthScore = healthScore;
    _resultData['healthScore'] = l$healthScore;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$title = title;
    final l$size = size;
    final l$seeders = seeders;
    final l$leechers = leechers;
    final l$magnetLink = magnetLink;
    final l$indexer = indexer;
    final l$quality = quality;
    final l$healthScore = healthScore;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$title,
      l$size,
      l$seeders,
      l$leechers,
      l$magnetLink,
      l$indexer,
      l$quality,
      l$healthScore,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$TorrentCandidates$torrentCandidates ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$title = title;
    final lOther$title = other.title;
    if (l$title != lOther$title) {
      return false;
    }
    final l$size = size;
    final lOther$size = other.size;
    if (l$size != lOther$size) {
      return false;
    }
    final l$seeders = seeders;
    final lOther$seeders = other.seeders;
    if (l$seeders != lOther$seeders) {
      return false;
    }
    final l$leechers = leechers;
    final lOther$leechers = other.leechers;
    if (l$leechers != lOther$leechers) {
      return false;
    }
    final l$magnetLink = magnetLink;
    final lOther$magnetLink = other.magnetLink;
    if (l$magnetLink != lOther$magnetLink) {
      return false;
    }
    final l$indexer = indexer;
    final lOther$indexer = other.indexer;
    if (l$indexer != lOther$indexer) {
      return false;
    }
    final l$quality = quality;
    final lOther$quality = other.quality;
    if (l$quality != lOther$quality) {
      return false;
    }
    final l$healthScore = healthScore;
    final lOther$healthScore = other.healthScore;
    if (l$healthScore != lOther$healthScore) {
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

extension UtilityExtension$Query$TorrentCandidates$torrentCandidates
    on Query$TorrentCandidates$torrentCandidates {
  CopyWith$Query$TorrentCandidates$torrentCandidates<
    Query$TorrentCandidates$torrentCandidates
  >
  get copyWith =>
      CopyWith$Query$TorrentCandidates$torrentCandidates(this, (i) => i);
}

abstract class CopyWith$Query$TorrentCandidates$torrentCandidates<TRes> {
  factory CopyWith$Query$TorrentCandidates$torrentCandidates(
    Query$TorrentCandidates$torrentCandidates instance,
    TRes Function(Query$TorrentCandidates$torrentCandidates) then,
  ) = _CopyWithImpl$Query$TorrentCandidates$torrentCandidates;

  factory CopyWith$Query$TorrentCandidates$torrentCandidates.stub(TRes res) =
      _CopyWithStubImpl$Query$TorrentCandidates$torrentCandidates;

  TRes call({
    String? title,
    int? size,
    int? seeders,
    int? leechers,
    String? magnetLink,
    String? indexer,
    String? quality,
    double? healthScore,
    String? $__typename,
  });
}

class _CopyWithImpl$Query$TorrentCandidates$torrentCandidates<TRes>
    implements CopyWith$Query$TorrentCandidates$torrentCandidates<TRes> {
  _CopyWithImpl$Query$TorrentCandidates$torrentCandidates(
    this._instance,
    this._then,
  );

  final Query$TorrentCandidates$torrentCandidates _instance;

  final TRes Function(Query$TorrentCandidates$torrentCandidates) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? title = _undefined,
    Object? size = _undefined,
    Object? seeders = _undefined,
    Object? leechers = _undefined,
    Object? magnetLink = _undefined,
    Object? indexer = _undefined,
    Object? quality = _undefined,
    Object? healthScore = _undefined,
    Object? $__typename = _undefined,
  }) => _then(
    Query$TorrentCandidates$torrentCandidates(
      title: title == _undefined || title == null
          ? _instance.title
          : (title as String),
      size: size == _undefined || size == null ? _instance.size : (size as int),
      seeders: seeders == _undefined ? _instance.seeders : (seeders as int?),
      leechers: leechers == _undefined
          ? _instance.leechers
          : (leechers as int?),
      magnetLink: magnetLink == _undefined || magnetLink == null
          ? _instance.magnetLink
          : (magnetLink as String),
      indexer: indexer == _undefined || indexer == null
          ? _instance.indexer
          : (indexer as String),
      quality: quality == _undefined ? _instance.quality : (quality as String?),
      healthScore: healthScore == _undefined || healthScore == null
          ? _instance.healthScore
          : (healthScore as double),
      $__typename: $__typename == _undefined || $__typename == null
          ? _instance.$__typename
          : ($__typename as String),
    ),
  );
}

class _CopyWithStubImpl$Query$TorrentCandidates$torrentCandidates<TRes>
    implements CopyWith$Query$TorrentCandidates$torrentCandidates<TRes> {
  _CopyWithStubImpl$Query$TorrentCandidates$torrentCandidates(this._res);

  TRes _res;

  call({
    String? title,
    int? size,
    int? seeders,
    int? leechers,
    String? magnetLink,
    String? indexer,
    String? quality,
    double? healthScore,
    String? $__typename,
  }) => _res;
}
