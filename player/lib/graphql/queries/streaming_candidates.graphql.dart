import '../schema.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Query$StreamingCandidates {
  factory Variables$Query$StreamingCandidates({
    required String contentType,
    required String id,
  }) =>
      Variables$Query$StreamingCandidates._({
        r'contentType': contentType,
        r'id': id,
      });

  Variables$Query$StreamingCandidates._(this._$data);

  factory Variables$Query$StreamingCandidates.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$contentType = data['contentType'];
    result$data['contentType'] = (l$contentType as String);
    final l$id = data['id'];
    result$data['id'] = (l$id as String);
    return Variables$Query$StreamingCandidates._(result$data);
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

  CopyWith$Variables$Query$StreamingCandidates<
          Variables$Query$StreamingCandidates>
      get copyWith =>
          CopyWith$Variables$Query$StreamingCandidates(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Query$StreamingCandidates ||
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

abstract class CopyWith$Variables$Query$StreamingCandidates<TRes> {
  factory CopyWith$Variables$Query$StreamingCandidates(
    Variables$Query$StreamingCandidates instance,
    TRes Function(Variables$Query$StreamingCandidates) then,
  ) = _CopyWithImpl$Variables$Query$StreamingCandidates;

  factory CopyWith$Variables$Query$StreamingCandidates.stub(TRes res) =
      _CopyWithStubImpl$Variables$Query$StreamingCandidates;

  TRes call({String? contentType, String? id});
}

class _CopyWithImpl$Variables$Query$StreamingCandidates<TRes>
    implements CopyWith$Variables$Query$StreamingCandidates<TRes> {
  _CopyWithImpl$Variables$Query$StreamingCandidates(this._instance, this._then);

  final Variables$Query$StreamingCandidates _instance;

  final TRes Function(Variables$Query$StreamingCandidates) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? contentType = _undefined, Object? id = _undefined}) =>
      _then(
        Variables$Query$StreamingCandidates._({
          ..._instance._$data,
          if (contentType != _undefined && contentType != null)
            'contentType': (contentType as String),
          if (id != _undefined && id != null) 'id': (id as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Query$StreamingCandidates<TRes>
    implements CopyWith$Variables$Query$StreamingCandidates<TRes> {
  _CopyWithStubImpl$Variables$Query$StreamingCandidates(this._res);

  TRes _res;

  call({String? contentType, String? id}) => _res;
}

class Query$StreamingCandidates {
  Query$StreamingCandidates({
    this.streamingCandidates,
    this.$__typename = 'RootQueryType',
  });

  factory Query$StreamingCandidates.fromJson(Map<String, dynamic> json) {
    final l$streamingCandidates = json['streamingCandidates'];
    final l$$__typename = json['__typename'];
    return Query$StreamingCandidates(
      streamingCandidates: l$streamingCandidates == null
          ? null
          : Query$StreamingCandidates$streamingCandidates.fromJson(
              (l$streamingCandidates as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Query$StreamingCandidates$streamingCandidates? streamingCandidates;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$streamingCandidates = streamingCandidates;
    _resultData['streamingCandidates'] = l$streamingCandidates?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$streamingCandidates = streamingCandidates;
    final l$$__typename = $__typename;
    return Object.hashAll([l$streamingCandidates, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$StreamingCandidates ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$streamingCandidates = streamingCandidates;
    final lOther$streamingCandidates = other.streamingCandidates;
    if (l$streamingCandidates != lOther$streamingCandidates) {
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

extension UtilityExtension$Query$StreamingCandidates
    on Query$StreamingCandidates {
  CopyWith$Query$StreamingCandidates<Query$StreamingCandidates> get copyWith =>
      CopyWith$Query$StreamingCandidates(this, (i) => i);
}

abstract class CopyWith$Query$StreamingCandidates<TRes> {
  factory CopyWith$Query$StreamingCandidates(
    Query$StreamingCandidates instance,
    TRes Function(Query$StreamingCandidates) then,
  ) = _CopyWithImpl$Query$StreamingCandidates;

  factory CopyWith$Query$StreamingCandidates.stub(TRes res) =
      _CopyWithStubImpl$Query$StreamingCandidates;

  TRes call({
    Query$StreamingCandidates$streamingCandidates? streamingCandidates,
    String? $__typename,
  });
  CopyWith$Query$StreamingCandidates$streamingCandidates<TRes>
      get streamingCandidates;
}

class _CopyWithImpl$Query$StreamingCandidates<TRes>
    implements CopyWith$Query$StreamingCandidates<TRes> {
  _CopyWithImpl$Query$StreamingCandidates(this._instance, this._then);

  final Query$StreamingCandidates _instance;

  final TRes Function(Query$StreamingCandidates) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? streamingCandidates = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$StreamingCandidates(
          streamingCandidates: streamingCandidates == _undefined
              ? _instance.streamingCandidates
              : (streamingCandidates
                  as Query$StreamingCandidates$streamingCandidates?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Query$StreamingCandidates$streamingCandidates<TRes>
      get streamingCandidates {
    final local$streamingCandidates = _instance.streamingCandidates;
    return local$streamingCandidates == null
        ? CopyWith$Query$StreamingCandidates$streamingCandidates.stub(
            _then(_instance),
          )
        : CopyWith$Query$StreamingCandidates$streamingCandidates(
            local$streamingCandidates,
            (e) => call(streamingCandidates: e),
          );
  }
}

class _CopyWithStubImpl$Query$StreamingCandidates<TRes>
    implements CopyWith$Query$StreamingCandidates<TRes> {
  _CopyWithStubImpl$Query$StreamingCandidates(this._res);

  TRes _res;

  call({
    Query$StreamingCandidates$streamingCandidates? streamingCandidates,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Query$StreamingCandidates$streamingCandidates<TRes>
      get streamingCandidates =>
          CopyWith$Query$StreamingCandidates$streamingCandidates.stub(_res);
}

const documentNodeQueryStreamingCandidates = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.query,
      name: NameNode(value: 'StreamingCandidates'),
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
            name: NameNode(value: 'streamingCandidates'),
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
                  name: NameNode(value: 'fileId'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'candidates'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: SelectionSetNode(
                    selections: [
                      FieldNode(
                        name: NameNode(value: 'strategy'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'mime'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'container'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'videoCodec'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'audioCodec'),
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
                  name: NameNode(value: 'metadata'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: SelectionSetNode(
                    selections: [
                      FieldNode(
                        name: NameNode(value: 'duration'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'width'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'height'),
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

class Query$StreamingCandidates$streamingCandidates {
  Query$StreamingCandidates$streamingCandidates({
    required this.fileId,
    required this.candidates,
    required this.metadata,
    this.$__typename = 'StreamingCandidatesResult',
  });

  factory Query$StreamingCandidates$streamingCandidates.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$fileId = json['fileId'];
    final l$candidates = json['candidates'];
    final l$metadata = json['metadata'];
    final l$$__typename = json['__typename'];
    return Query$StreamingCandidates$streamingCandidates(
      fileId: (l$fileId as String),
      candidates: (l$candidates as List<dynamic>)
          .map(
            (e) => Query$StreamingCandidates$streamingCandidates$candidates
                .fromJson(
              (e as Map<String, dynamic>),
            ),
          )
          .toList(),
      metadata: Query$StreamingCandidates$streamingCandidates$metadata.fromJson(
        (l$metadata as Map<String, dynamic>),
      ),
      $__typename: (l$$__typename as String),
    );
  }

  final String fileId;

  final List<Query$StreamingCandidates$streamingCandidates$candidates>
      candidates;

  final Query$StreamingCandidates$streamingCandidates$metadata metadata;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$fileId = fileId;
    _resultData['fileId'] = l$fileId;
    final l$candidates = candidates;
    _resultData['candidates'] = l$candidates.map((e) => e.toJson()).toList();
    final l$metadata = metadata;
    _resultData['metadata'] = l$metadata.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$fileId = fileId;
    final l$candidates = candidates;
    final l$metadata = metadata;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$fileId,
      Object.hashAll(l$candidates.map((v) => v)),
      l$metadata,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$StreamingCandidates$streamingCandidates ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$fileId = fileId;
    final lOther$fileId = other.fileId;
    if (l$fileId != lOther$fileId) {
      return false;
    }
    final l$candidates = candidates;
    final lOther$candidates = other.candidates;
    if (l$candidates.length != lOther$candidates.length) {
      return false;
    }
    for (int i = 0; i < l$candidates.length; i++) {
      final l$candidates$entry = l$candidates[i];
      final lOther$candidates$entry = lOther$candidates[i];
      if (l$candidates$entry != lOther$candidates$entry) {
        return false;
      }
    }
    final l$metadata = metadata;
    final lOther$metadata = other.metadata;
    if (l$metadata != lOther$metadata) {
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

extension UtilityExtension$Query$StreamingCandidates$streamingCandidates
    on Query$StreamingCandidates$streamingCandidates {
  CopyWith$Query$StreamingCandidates$streamingCandidates<
          Query$StreamingCandidates$streamingCandidates>
      get copyWith => CopyWith$Query$StreamingCandidates$streamingCandidates(
          this, (i) => i);
}

abstract class CopyWith$Query$StreamingCandidates$streamingCandidates<TRes> {
  factory CopyWith$Query$StreamingCandidates$streamingCandidates(
    Query$StreamingCandidates$streamingCandidates instance,
    TRes Function(Query$StreamingCandidates$streamingCandidates) then,
  ) = _CopyWithImpl$Query$StreamingCandidates$streamingCandidates;

  factory CopyWith$Query$StreamingCandidates$streamingCandidates.stub(
    TRes res,
  ) = _CopyWithStubImpl$Query$StreamingCandidates$streamingCandidates;

  TRes call({
    String? fileId,
    List<Query$StreamingCandidates$streamingCandidates$candidates>? candidates,
    Query$StreamingCandidates$streamingCandidates$metadata? metadata,
    String? $__typename,
  });
  TRes candidates(
    Iterable<Query$StreamingCandidates$streamingCandidates$candidates> Function(
      Iterable<
          CopyWith$Query$StreamingCandidates$streamingCandidates$candidates<
              Query$StreamingCandidates$streamingCandidates$candidates>>,
    ) _fn,
  );
  CopyWith$Query$StreamingCandidates$streamingCandidates$metadata<TRes>
      get metadata;
}

class _CopyWithImpl$Query$StreamingCandidates$streamingCandidates<TRes>
    implements CopyWith$Query$StreamingCandidates$streamingCandidates<TRes> {
  _CopyWithImpl$Query$StreamingCandidates$streamingCandidates(
    this._instance,
    this._then,
  );

  final Query$StreamingCandidates$streamingCandidates _instance;

  final TRes Function(Query$StreamingCandidates$streamingCandidates) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? fileId = _undefined,
    Object? candidates = _undefined,
    Object? metadata = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$StreamingCandidates$streamingCandidates(
          fileId: fileId == _undefined || fileId == null
              ? _instance.fileId
              : (fileId as String),
          candidates: candidates == _undefined || candidates == null
              ? _instance.candidates
              : (candidates as List<
                  Query$StreamingCandidates$streamingCandidates$candidates>),
          metadata: metadata == _undefined || metadata == null
              ? _instance.metadata
              : (metadata
                  as Query$StreamingCandidates$streamingCandidates$metadata),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  TRes candidates(
    Iterable<Query$StreamingCandidates$streamingCandidates$candidates> Function(
      Iterable<
          CopyWith$Query$StreamingCandidates$streamingCandidates$candidates<
              Query$StreamingCandidates$streamingCandidates$candidates>>,
    ) _fn,
  ) =>
      call(
        candidates: _fn(
          _instance.candidates.map(
            (e) =>
                CopyWith$Query$StreamingCandidates$streamingCandidates$candidates(
              e,
              (i) => i,
            ),
          ),
        ).toList(),
      );

  CopyWith$Query$StreamingCandidates$streamingCandidates$metadata<TRes>
      get metadata {
    final local$metadata = _instance.metadata;
    return CopyWith$Query$StreamingCandidates$streamingCandidates$metadata(
      local$metadata,
      (e) => call(metadata: e),
    );
  }
}

class _CopyWithStubImpl$Query$StreamingCandidates$streamingCandidates<TRes>
    implements CopyWith$Query$StreamingCandidates$streamingCandidates<TRes> {
  _CopyWithStubImpl$Query$StreamingCandidates$streamingCandidates(this._res);

  TRes _res;

  call({
    String? fileId,
    List<Query$StreamingCandidates$streamingCandidates$candidates>? candidates,
    Query$StreamingCandidates$streamingCandidates$metadata? metadata,
    String? $__typename,
  }) =>
      _res;

  candidates(_fn) => _res;

  CopyWith$Query$StreamingCandidates$streamingCandidates$metadata<TRes>
      get metadata =>
          CopyWith$Query$StreamingCandidates$streamingCandidates$metadata.stub(
            _res,
          );
}

class Query$StreamingCandidates$streamingCandidates$candidates {
  Query$StreamingCandidates$streamingCandidates$candidates({
    required this.strategy,
    required this.mime,
    required this.container,
    this.videoCodec,
    this.audioCodec,
    this.$__typename = 'StreamingCandidate',
  });

  factory Query$StreamingCandidates$streamingCandidates$candidates.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$strategy = json['strategy'];
    final l$mime = json['mime'];
    final l$container = json['container'];
    final l$videoCodec = json['videoCodec'];
    final l$audioCodec = json['audioCodec'];
    final l$$__typename = json['__typename'];
    return Query$StreamingCandidates$streamingCandidates$candidates(
      strategy: fromJson$Enum$StreamingCandidateStrategy(
        (l$strategy as String),
      ),
      mime: (l$mime as String),
      container: (l$container as String),
      videoCodec: (l$videoCodec as String?),
      audioCodec: (l$audioCodec as String?),
      $__typename: (l$$__typename as String),
    );
  }

  final Enum$StreamingCandidateStrategy strategy;

  final String mime;

  final String container;

  final String? videoCodec;

  final String? audioCodec;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$strategy = strategy;
    _resultData['strategy'] = toJson$Enum$StreamingCandidateStrategy(
      l$strategy,
    );
    final l$mime = mime;
    _resultData['mime'] = l$mime;
    final l$container = container;
    _resultData['container'] = l$container;
    final l$videoCodec = videoCodec;
    _resultData['videoCodec'] = l$videoCodec;
    final l$audioCodec = audioCodec;
    _resultData['audioCodec'] = l$audioCodec;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$strategy = strategy;
    final l$mime = mime;
    final l$container = container;
    final l$videoCodec = videoCodec;
    final l$audioCodec = audioCodec;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$strategy,
      l$mime,
      l$container,
      l$videoCodec,
      l$audioCodec,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$StreamingCandidates$streamingCandidates$candidates ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$strategy = strategy;
    final lOther$strategy = other.strategy;
    if (l$strategy != lOther$strategy) {
      return false;
    }
    final l$mime = mime;
    final lOther$mime = other.mime;
    if (l$mime != lOther$mime) {
      return false;
    }
    final l$container = container;
    final lOther$container = other.container;
    if (l$container != lOther$container) {
      return false;
    }
    final l$videoCodec = videoCodec;
    final lOther$videoCodec = other.videoCodec;
    if (l$videoCodec != lOther$videoCodec) {
      return false;
    }
    final l$audioCodec = audioCodec;
    final lOther$audioCodec = other.audioCodec;
    if (l$audioCodec != lOther$audioCodec) {
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

extension UtilityExtension$Query$StreamingCandidates$streamingCandidates$candidates
    on Query$StreamingCandidates$streamingCandidates$candidates {
  CopyWith$Query$StreamingCandidates$streamingCandidates$candidates<
          Query$StreamingCandidates$streamingCandidates$candidates>
      get copyWith =>
          CopyWith$Query$StreamingCandidates$streamingCandidates$candidates(
            this,
            (i) => i,
          );
}

abstract class CopyWith$Query$StreamingCandidates$streamingCandidates$candidates<
    TRes> {
  factory CopyWith$Query$StreamingCandidates$streamingCandidates$candidates(
    Query$StreamingCandidates$streamingCandidates$candidates instance,
    TRes Function(Query$StreamingCandidates$streamingCandidates$candidates)
        then,
  ) = _CopyWithImpl$Query$StreamingCandidates$streamingCandidates$candidates;

  factory CopyWith$Query$StreamingCandidates$streamingCandidates$candidates.stub(
    TRes res,
  ) = _CopyWithStubImpl$Query$StreamingCandidates$streamingCandidates$candidates;

  TRes call({
    Enum$StreamingCandidateStrategy? strategy,
    String? mime,
    String? container,
    String? videoCodec,
    String? audioCodec,
    String? $__typename,
  });
}

class _CopyWithImpl$Query$StreamingCandidates$streamingCandidates$candidates<
        TRes>
    implements
        CopyWith$Query$StreamingCandidates$streamingCandidates$candidates<
            TRes> {
  _CopyWithImpl$Query$StreamingCandidates$streamingCandidates$candidates(
    this._instance,
    this._then,
  );

  final Query$StreamingCandidates$streamingCandidates$candidates _instance;

  final TRes Function(Query$StreamingCandidates$streamingCandidates$candidates)
      _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? strategy = _undefined,
    Object? mime = _undefined,
    Object? container = _undefined,
    Object? videoCodec = _undefined,
    Object? audioCodec = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$StreamingCandidates$streamingCandidates$candidates(
          strategy: strategy == _undefined || strategy == null
              ? _instance.strategy
              : (strategy as Enum$StreamingCandidateStrategy),
          mime: mime == _undefined || mime == null
              ? _instance.mime
              : (mime as String),
          container: container == _undefined || container == null
              ? _instance.container
              : (container as String),
          videoCodec: videoCodec == _undefined
              ? _instance.videoCodec
              : (videoCodec as String?),
          audioCodec: audioCodec == _undefined
              ? _instance.audioCodec
              : (audioCodec as String?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Query$StreamingCandidates$streamingCandidates$candidates<
        TRes>
    implements
        CopyWith$Query$StreamingCandidates$streamingCandidates$candidates<
            TRes> {
  _CopyWithStubImpl$Query$StreamingCandidates$streamingCandidates$candidates(
    this._res,
  );

  TRes _res;

  call({
    Enum$StreamingCandidateStrategy? strategy,
    String? mime,
    String? container,
    String? videoCodec,
    String? audioCodec,
    String? $__typename,
  }) =>
      _res;
}

class Query$StreamingCandidates$streamingCandidates$metadata {
  Query$StreamingCandidates$streamingCandidates$metadata({
    this.duration,
    this.width,
    this.height,
    this.$__typename = 'StreamingMetadata',
  });

  factory Query$StreamingCandidates$streamingCandidates$metadata.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$duration = json['duration'];
    final l$width = json['width'];
    final l$height = json['height'];
    final l$$__typename = json['__typename'];
    return Query$StreamingCandidates$streamingCandidates$metadata(
      duration: (l$duration as num?)?.toDouble(),
      width: (l$width as int?),
      height: (l$height as int?),
      $__typename: (l$$__typename as String),
    );
  }

  final double? duration;

  final int? width;

  final int? height;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$duration = duration;
    _resultData['duration'] = l$duration;
    final l$width = width;
    _resultData['width'] = l$width;
    final l$height = height;
    _resultData['height'] = l$height;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$duration = duration;
    final l$width = width;
    final l$height = height;
    final l$$__typename = $__typename;
    return Object.hashAll([l$duration, l$width, l$height, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$StreamingCandidates$streamingCandidates$metadata ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$duration = duration;
    final lOther$duration = other.duration;
    if (l$duration != lOther$duration) {
      return false;
    }
    final l$width = width;
    final lOther$width = other.width;
    if (l$width != lOther$width) {
      return false;
    }
    final l$height = height;
    final lOther$height = other.height;
    if (l$height != lOther$height) {
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

extension UtilityExtension$Query$StreamingCandidates$streamingCandidates$metadata
    on Query$StreamingCandidates$streamingCandidates$metadata {
  CopyWith$Query$StreamingCandidates$streamingCandidates$metadata<
          Query$StreamingCandidates$streamingCandidates$metadata>
      get copyWith =>
          CopyWith$Query$StreamingCandidates$streamingCandidates$metadata(
            this,
            (i) => i,
          );
}

abstract class CopyWith$Query$StreamingCandidates$streamingCandidates$metadata<
    TRes> {
  factory CopyWith$Query$StreamingCandidates$streamingCandidates$metadata(
    Query$StreamingCandidates$streamingCandidates$metadata instance,
    TRes Function(Query$StreamingCandidates$streamingCandidates$metadata) then,
  ) = _CopyWithImpl$Query$StreamingCandidates$streamingCandidates$metadata;

  factory CopyWith$Query$StreamingCandidates$streamingCandidates$metadata.stub(
    TRes res,
  ) = _CopyWithStubImpl$Query$StreamingCandidates$streamingCandidates$metadata;

  TRes call({double? duration, int? width, int? height, String? $__typename});
}

class _CopyWithImpl$Query$StreamingCandidates$streamingCandidates$metadata<TRes>
    implements
        CopyWith$Query$StreamingCandidates$streamingCandidates$metadata<TRes> {
  _CopyWithImpl$Query$StreamingCandidates$streamingCandidates$metadata(
    this._instance,
    this._then,
  );

  final Query$StreamingCandidates$streamingCandidates$metadata _instance;

  final TRes Function(Query$StreamingCandidates$streamingCandidates$metadata)
      _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? duration = _undefined,
    Object? width = _undefined,
    Object? height = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$StreamingCandidates$streamingCandidates$metadata(
          duration: duration == _undefined
              ? _instance.duration
              : (duration as double?),
          width: width == _undefined ? _instance.width : (width as int?),
          height: height == _undefined ? _instance.height : (height as int?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Query$StreamingCandidates$streamingCandidates$metadata<
        TRes>
    implements
        CopyWith$Query$StreamingCandidates$streamingCandidates$metadata<TRes> {
  _CopyWithStubImpl$Query$StreamingCandidates$streamingCandidates$metadata(
    this._res,
  );

  TRes _res;

  call({double? duration, int? width, int? height, String? $__typename}) =>
      _res;
}
