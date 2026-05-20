import 'package:gql/ast.dart';

class Variables$Mutation$EndTorrentSession {
  factory Variables$Mutation$EndTorrentSession({required String sessionId}) =>
      Variables$Mutation$EndTorrentSession._({r'sessionId': sessionId});

  Variables$Mutation$EndTorrentSession._(this._$data);

  factory Variables$Mutation$EndTorrentSession.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$sessionId = data['sessionId'];
    result$data['sessionId'] = (l$sessionId as String);
    return Variables$Mutation$EndTorrentSession._(result$data);
  }

  Map<String, dynamic> _$data;

  String get sessionId => (_$data['sessionId'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$sessionId = sessionId;
    result$data['sessionId'] = l$sessionId;
    return result$data;
  }

  CopyWith$Variables$Mutation$EndTorrentSession<
    Variables$Mutation$EndTorrentSession
  >
  get copyWith => CopyWith$Variables$Mutation$EndTorrentSession(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$EndTorrentSession ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$sessionId = sessionId;
    final lOther$sessionId = other.sessionId;
    if (l$sessionId != lOther$sessionId) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$sessionId = sessionId;
    return Object.hashAll([l$sessionId]);
  }
}

abstract class CopyWith$Variables$Mutation$EndTorrentSession<TRes> {
  factory CopyWith$Variables$Mutation$EndTorrentSession(
    Variables$Mutation$EndTorrentSession instance,
    TRes Function(Variables$Mutation$EndTorrentSession) then,
  ) = _CopyWithImpl$Variables$Mutation$EndTorrentSession;

  factory CopyWith$Variables$Mutation$EndTorrentSession.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$EndTorrentSession;

  TRes call({String? sessionId});
}

class _CopyWithImpl$Variables$Mutation$EndTorrentSession<TRes>
    implements CopyWith$Variables$Mutation$EndTorrentSession<TRes> {
  _CopyWithImpl$Variables$Mutation$EndTorrentSession(
    this._instance,
    this._then,
  );

  final Variables$Mutation$EndTorrentSession _instance;

  final TRes Function(Variables$Mutation$EndTorrentSession) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? sessionId = _undefined}) => _then(
    Variables$Mutation$EndTorrentSession._({
      ..._instance._$data,
      if (sessionId != _undefined && sessionId != null)
        'sessionId': (sessionId as String),
    }),
  );
}

class _CopyWithStubImpl$Variables$Mutation$EndTorrentSession<TRes>
    implements CopyWith$Variables$Mutation$EndTorrentSession<TRes> {
  _CopyWithStubImpl$Variables$Mutation$EndTorrentSession(this._res);

  TRes _res;

  call({String? sessionId}) => _res;
}

class Mutation$EndTorrentSession {
  Mutation$EndTorrentSession({
    this.endTorrentSession,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$EndTorrentSession.fromJson(Map<String, dynamic> json) {
    final l$endTorrentSession = json['endTorrentSession'];
    final l$$__typename = json['__typename'];
    return Mutation$EndTorrentSession(
      endTorrentSession: (l$endTorrentSession as bool?),
      $__typename: (l$$__typename as String),
    );
  }

  final bool? endTorrentSession;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$endTorrentSession = endTorrentSession;
    _resultData['endTorrentSession'] = l$endTorrentSession;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$endTorrentSession = endTorrentSession;
    final l$$__typename = $__typename;
    return Object.hashAll([l$endTorrentSession, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$EndTorrentSession ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$endTorrentSession = endTorrentSession;
    final lOther$endTorrentSession = other.endTorrentSession;
    if (l$endTorrentSession != lOther$endTorrentSession) {
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

extension UtilityExtension$Mutation$EndTorrentSession
    on Mutation$EndTorrentSession {
  CopyWith$Mutation$EndTorrentSession<Mutation$EndTorrentSession>
  get copyWith => CopyWith$Mutation$EndTorrentSession(this, (i) => i);
}

abstract class CopyWith$Mutation$EndTorrentSession<TRes> {
  factory CopyWith$Mutation$EndTorrentSession(
    Mutation$EndTorrentSession instance,
    TRes Function(Mutation$EndTorrentSession) then,
  ) = _CopyWithImpl$Mutation$EndTorrentSession;

  factory CopyWith$Mutation$EndTorrentSession.stub(TRes res) =
      _CopyWithStubImpl$Mutation$EndTorrentSession;

  TRes call({bool? endTorrentSession, String? $__typename});
}

class _CopyWithImpl$Mutation$EndTorrentSession<TRes>
    implements CopyWith$Mutation$EndTorrentSession<TRes> {
  _CopyWithImpl$Mutation$EndTorrentSession(this._instance, this._then);

  final Mutation$EndTorrentSession _instance;

  final TRes Function(Mutation$EndTorrentSession) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? endTorrentSession = _undefined,
    Object? $__typename = _undefined,
  }) => _then(
    Mutation$EndTorrentSession(
      endTorrentSession: endTorrentSession == _undefined
          ? _instance.endTorrentSession
          : (endTorrentSession as bool?),
      $__typename: $__typename == _undefined || $__typename == null
          ? _instance.$__typename
          : ($__typename as String),
    ),
  );
}

class _CopyWithStubImpl$Mutation$EndTorrentSession<TRes>
    implements CopyWith$Mutation$EndTorrentSession<TRes> {
  _CopyWithStubImpl$Mutation$EndTorrentSession(this._res);

  TRes _res;

  call({bool? endTorrentSession, String? $__typename}) => _res;
}

const documentNodeMutationEndTorrentSession = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'EndTorrentSession'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'sessionId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'endTorrentSession'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'sessionId'),
                value: VariableNode(name: NameNode(value: 'sessionId')),
              ),
            ],
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
  ],
);
