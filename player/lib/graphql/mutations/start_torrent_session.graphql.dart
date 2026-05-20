import 'package:gql/ast.dart';

class Variables$Mutation$StartTorrentSession {
  factory Variables$Mutation$StartTorrentSession({
    required String magnetLink,
    required String releaseTitle,
    String? mediaItemId,
    String? episodeId,
  }) => Variables$Mutation$StartTorrentSession._({
    r'magnetLink': magnetLink,
    r'releaseTitle': releaseTitle,
    if (mediaItemId != null) r'mediaItemId': mediaItemId,
    if (episodeId != null) r'episodeId': episodeId,
  });

  Variables$Mutation$StartTorrentSession._(this._$data);

  factory Variables$Mutation$StartTorrentSession.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$magnetLink = data['magnetLink'];
    result$data['magnetLink'] = (l$magnetLink as String);
    final l$releaseTitle = data['releaseTitle'];
    result$data['releaseTitle'] = (l$releaseTitle as String);
    if (data.containsKey('mediaItemId')) {
      final l$mediaItemId = data['mediaItemId'];
      result$data['mediaItemId'] = (l$mediaItemId as String?);
    }
    if (data.containsKey('episodeId')) {
      final l$episodeId = data['episodeId'];
      result$data['episodeId'] = (l$episodeId as String?);
    }
    return Variables$Mutation$StartTorrentSession._(result$data);
  }

  Map<String, dynamic> _$data;

  String get magnetLink => (_$data['magnetLink'] as String);

  String get releaseTitle => (_$data['releaseTitle'] as String);

  String? get mediaItemId => (_$data['mediaItemId'] as String?);

  String? get episodeId => (_$data['episodeId'] as String?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$magnetLink = magnetLink;
    result$data['magnetLink'] = l$magnetLink;
    final l$releaseTitle = releaseTitle;
    result$data['releaseTitle'] = l$releaseTitle;
    if (_$data.containsKey('mediaItemId')) {
      final l$mediaItemId = mediaItemId;
      result$data['mediaItemId'] = l$mediaItemId;
    }
    if (_$data.containsKey('episodeId')) {
      final l$episodeId = episodeId;
      result$data['episodeId'] = l$episodeId;
    }
    return result$data;
  }

  CopyWith$Variables$Mutation$StartTorrentSession<
    Variables$Mutation$StartTorrentSession
  >
  get copyWith =>
      CopyWith$Variables$Mutation$StartTorrentSession(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$StartTorrentSession ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$magnetLink = magnetLink;
    final lOther$magnetLink = other.magnetLink;
    if (l$magnetLink != lOther$magnetLink) {
      return false;
    }
    final l$releaseTitle = releaseTitle;
    final lOther$releaseTitle = other.releaseTitle;
    if (l$releaseTitle != lOther$releaseTitle) {
      return false;
    }
    final l$mediaItemId = mediaItemId;
    final lOther$mediaItemId = other.mediaItemId;
    if (_$data.containsKey('mediaItemId') !=
        other._$data.containsKey('mediaItemId')) {
      return false;
    }
    if (l$mediaItemId != lOther$mediaItemId) {
      return false;
    }
    final l$episodeId = episodeId;
    final lOther$episodeId = other.episodeId;
    if (_$data.containsKey('episodeId') !=
        other._$data.containsKey('episodeId')) {
      return false;
    }
    if (l$episodeId != lOther$episodeId) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$magnetLink = magnetLink;
    final l$releaseTitle = releaseTitle;
    final l$mediaItemId = mediaItemId;
    final l$episodeId = episodeId;
    return Object.hashAll([
      l$magnetLink,
      l$releaseTitle,
      _$data.containsKey('mediaItemId') ? l$mediaItemId : const {},
      _$data.containsKey('episodeId') ? l$episodeId : const {},
    ]);
  }
}

abstract class CopyWith$Variables$Mutation$StartTorrentSession<TRes> {
  factory CopyWith$Variables$Mutation$StartTorrentSession(
    Variables$Mutation$StartTorrentSession instance,
    TRes Function(Variables$Mutation$StartTorrentSession) then,
  ) = _CopyWithImpl$Variables$Mutation$StartTorrentSession;

  factory CopyWith$Variables$Mutation$StartTorrentSession.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$StartTorrentSession;

  TRes call({
    String? magnetLink,
    String? releaseTitle,
    String? mediaItemId,
    String? episodeId,
  });
}

class _CopyWithImpl$Variables$Mutation$StartTorrentSession<TRes>
    implements CopyWith$Variables$Mutation$StartTorrentSession<TRes> {
  _CopyWithImpl$Variables$Mutation$StartTorrentSession(
    this._instance,
    this._then,
  );

  final Variables$Mutation$StartTorrentSession _instance;

  final TRes Function(Variables$Mutation$StartTorrentSession) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? magnetLink = _undefined,
    Object? releaseTitle = _undefined,
    Object? mediaItemId = _undefined,
    Object? episodeId = _undefined,
  }) => _then(
    Variables$Mutation$StartTorrentSession._({
      ..._instance._$data,
      if (magnetLink != _undefined && magnetLink != null)
        'magnetLink': (magnetLink as String),
      if (releaseTitle != _undefined && releaseTitle != null)
        'releaseTitle': (releaseTitle as String),
      if (mediaItemId != _undefined) 'mediaItemId': (mediaItemId as String?),
      if (episodeId != _undefined) 'episodeId': (episodeId as String?),
    }),
  );
}

class _CopyWithStubImpl$Variables$Mutation$StartTorrentSession<TRes>
    implements CopyWith$Variables$Mutation$StartTorrentSession<TRes> {
  _CopyWithStubImpl$Variables$Mutation$StartTorrentSession(this._res);

  TRes _res;

  call({
    String? magnetLink,
    String? releaseTitle,
    String? mediaItemId,
    String? episodeId,
  }) => _res;
}

class Mutation$StartTorrentSession {
  Mutation$StartTorrentSession({
    this.startTorrentSession,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$StartTorrentSession.fromJson(Map<String, dynamic> json) {
    final l$startTorrentSession = json['startTorrentSession'];
    final l$$__typename = json['__typename'];
    return Mutation$StartTorrentSession(
      startTorrentSession: l$startTorrentSession == null
          ? null
          : Mutation$StartTorrentSession$startTorrentSession.fromJson(
              (l$startTorrentSession as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$StartTorrentSession$startTorrentSession? startTorrentSession;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$startTorrentSession = startTorrentSession;
    _resultData['startTorrentSession'] = l$startTorrentSession?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$startTorrentSession = startTorrentSession;
    final l$$__typename = $__typename;
    return Object.hashAll([l$startTorrentSession, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$StartTorrentSession ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$startTorrentSession = startTorrentSession;
    final lOther$startTorrentSession = other.startTorrentSession;
    if (l$startTorrentSession != lOther$startTorrentSession) {
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

extension UtilityExtension$Mutation$StartTorrentSession
    on Mutation$StartTorrentSession {
  CopyWith$Mutation$StartTorrentSession<Mutation$StartTorrentSession>
  get copyWith => CopyWith$Mutation$StartTorrentSession(this, (i) => i);
}

abstract class CopyWith$Mutation$StartTorrentSession<TRes> {
  factory CopyWith$Mutation$StartTorrentSession(
    Mutation$StartTorrentSession instance,
    TRes Function(Mutation$StartTorrentSession) then,
  ) = _CopyWithImpl$Mutation$StartTorrentSession;

  factory CopyWith$Mutation$StartTorrentSession.stub(TRes res) =
      _CopyWithStubImpl$Mutation$StartTorrentSession;

  TRes call({
    Mutation$StartTorrentSession$startTorrentSession? startTorrentSession,
    String? $__typename,
  });
  CopyWith$Mutation$StartTorrentSession$startTorrentSession<TRes>
  get startTorrentSession;
}

class _CopyWithImpl$Mutation$StartTorrentSession<TRes>
    implements CopyWith$Mutation$StartTorrentSession<TRes> {
  _CopyWithImpl$Mutation$StartTorrentSession(this._instance, this._then);

  final Mutation$StartTorrentSession _instance;

  final TRes Function(Mutation$StartTorrentSession) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? startTorrentSession = _undefined,
    Object? $__typename = _undefined,
  }) => _then(
    Mutation$StartTorrentSession(
      startTorrentSession: startTorrentSession == _undefined
          ? _instance.startTorrentSession
          : (startTorrentSession
                as Mutation$StartTorrentSession$startTorrentSession?),
      $__typename: $__typename == _undefined || $__typename == null
          ? _instance.$__typename
          : ($__typename as String),
    ),
  );

  CopyWith$Mutation$StartTorrentSession$startTorrentSession<TRes>
  get startTorrentSession {
    final local$startTorrentSession = _instance.startTorrentSession;
    return local$startTorrentSession == null
        ? CopyWith$Mutation$StartTorrentSession$startTorrentSession.stub(
            _then(_instance),
          )
        : CopyWith$Mutation$StartTorrentSession$startTorrentSession(
            local$startTorrentSession,
            (e) => call(startTorrentSession: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$StartTorrentSession<TRes>
    implements CopyWith$Mutation$StartTorrentSession<TRes> {
  _CopyWithStubImpl$Mutation$StartTorrentSession(this._res);

  TRes _res;

  call({
    Mutation$StartTorrentSession$startTorrentSession? startTorrentSession,
    String? $__typename,
  }) => _res;

  CopyWith$Mutation$StartTorrentSession$startTorrentSession<TRes>
  get startTorrentSession =>
      CopyWith$Mutation$StartTorrentSession$startTorrentSession.stub(_res);
}

const documentNodeMutationStartTorrentSession = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'StartTorrentSession'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'magnetLink')),
          type: NamedTypeNode(name: NameNode(value: 'String'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'releaseTitle')),
          type: NamedTypeNode(name: NameNode(value: 'String'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'mediaItemId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: false),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'episodeId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: false),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'startTorrentSession'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'magnetLink'),
                value: VariableNode(name: NameNode(value: 'magnetLink')),
              ),
              ArgumentNode(
                name: NameNode(value: 'releaseTitle'),
                value: VariableNode(name: NameNode(value: 'releaseTitle')),
              ),
              ArgumentNode(
                name: NameNode(value: 'mediaItemId'),
                value: VariableNode(name: NameNode(value: 'mediaItemId')),
              ),
              ArgumentNode(
                name: NameNode(value: 'episodeId'),
                value: VariableNode(name: NameNode(value: 'episodeId')),
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
                  name: NameNode(value: 'magnetLink'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'releaseTitle'),
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

class Mutation$StartTorrentSession$startTorrentSession {
  Mutation$StartTorrentSession$startTorrentSession({
    required this.id,
    required this.magnetLink,
    required this.releaseTitle,
    this.$__typename = 'TorrentSession',
  });

  factory Mutation$StartTorrentSession$startTorrentSession.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$magnetLink = json['magnetLink'];
    final l$releaseTitle = json['releaseTitle'];
    final l$$__typename = json['__typename'];
    return Mutation$StartTorrentSession$startTorrentSession(
      id: (l$id as String),
      magnetLink: (l$magnetLink as String),
      releaseTitle: (l$releaseTitle as String),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String magnetLink;

  final String releaseTitle;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$magnetLink = magnetLink;
    _resultData['magnetLink'] = l$magnetLink;
    final l$releaseTitle = releaseTitle;
    _resultData['releaseTitle'] = l$releaseTitle;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$magnetLink = magnetLink;
    final l$releaseTitle = releaseTitle;
    final l$$__typename = $__typename;
    return Object.hashAll([l$id, l$magnetLink, l$releaseTitle, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$StartTorrentSession$startTorrentSession ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$magnetLink = magnetLink;
    final lOther$magnetLink = other.magnetLink;
    if (l$magnetLink != lOther$magnetLink) {
      return false;
    }
    final l$releaseTitle = releaseTitle;
    final lOther$releaseTitle = other.releaseTitle;
    if (l$releaseTitle != lOther$releaseTitle) {
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

extension UtilityExtension$Mutation$StartTorrentSession$startTorrentSession
    on Mutation$StartTorrentSession$startTorrentSession {
  CopyWith$Mutation$StartTorrentSession$startTorrentSession<
    Mutation$StartTorrentSession$startTorrentSession
  >
  get copyWith =>
      CopyWith$Mutation$StartTorrentSession$startTorrentSession(this, (i) => i);
}

abstract class CopyWith$Mutation$StartTorrentSession$startTorrentSession<TRes> {
  factory CopyWith$Mutation$StartTorrentSession$startTorrentSession(
    Mutation$StartTorrentSession$startTorrentSession instance,
    TRes Function(Mutation$StartTorrentSession$startTorrentSession) then,
  ) = _CopyWithImpl$Mutation$StartTorrentSession$startTorrentSession;

  factory CopyWith$Mutation$StartTorrentSession$startTorrentSession.stub(
    TRes res,
  ) = _CopyWithStubImpl$Mutation$StartTorrentSession$startTorrentSession;

  TRes call({
    String? id,
    String? magnetLink,
    String? releaseTitle,
    String? $__typename,
  });
}

class _CopyWithImpl$Mutation$StartTorrentSession$startTorrentSession<TRes>
    implements CopyWith$Mutation$StartTorrentSession$startTorrentSession<TRes> {
  _CopyWithImpl$Mutation$StartTorrentSession$startTorrentSession(
    this._instance,
    this._then,
  );

  final Mutation$StartTorrentSession$startTorrentSession _instance;

  final TRes Function(Mutation$StartTorrentSession$startTorrentSession) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? magnetLink = _undefined,
    Object? releaseTitle = _undefined,
    Object? $__typename = _undefined,
  }) => _then(
    Mutation$StartTorrentSession$startTorrentSession(
      id: id == _undefined || id == null ? _instance.id : (id as String),
      magnetLink: magnetLink == _undefined || magnetLink == null
          ? _instance.magnetLink
          : (magnetLink as String),
      releaseTitle: releaseTitle == _undefined || releaseTitle == null
          ? _instance.releaseTitle
          : (releaseTitle as String),
      $__typename: $__typename == _undefined || $__typename == null
          ? _instance.$__typename
          : ($__typename as String),
    ),
  );
}

class _CopyWithStubImpl$Mutation$StartTorrentSession$startTorrentSession<TRes>
    implements CopyWith$Mutation$StartTorrentSession$startTorrentSession<TRes> {
  _CopyWithStubImpl$Mutation$StartTorrentSession$startTorrentSession(this._res);

  TRes _res;

  call({
    String? id,
    String? magnetLink,
    String? releaseTitle,
    String? $__typename,
  }) => _res;
}
