import 'package:gql/ast.dart';

class Variables$Mutation$EndStreamingSession {
  factory Variables$Mutation$EndStreamingSession({required String sessionId}) =>
      Variables$Mutation$EndStreamingSession._({r'sessionId': sessionId});

  Variables$Mutation$EndStreamingSession._(this._$data);

  factory Variables$Mutation$EndStreamingSession.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$sessionId = data['sessionId'];
    result$data['sessionId'] = (l$sessionId as String);
    return Variables$Mutation$EndStreamingSession._(result$data);
  }

  Map<String, dynamic> _$data;

  String get sessionId => (_$data['sessionId'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$sessionId = sessionId;
    result$data['sessionId'] = l$sessionId;
    return result$data;
  }

  CopyWith$Variables$Mutation$EndStreamingSession<
          Variables$Mutation$EndStreamingSession>
      get copyWith =>
          CopyWith$Variables$Mutation$EndStreamingSession(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$EndStreamingSession ||
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

abstract class CopyWith$Variables$Mutation$EndStreamingSession<TRes> {
  factory CopyWith$Variables$Mutation$EndStreamingSession(
    Variables$Mutation$EndStreamingSession instance,
    TRes Function(Variables$Mutation$EndStreamingSession) then,
  ) = _CopyWithImpl$Variables$Mutation$EndStreamingSession;

  factory CopyWith$Variables$Mutation$EndStreamingSession.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$EndStreamingSession;

  TRes call({String? sessionId});
}

class _CopyWithImpl$Variables$Mutation$EndStreamingSession<TRes>
    implements CopyWith$Variables$Mutation$EndStreamingSession<TRes> {
  _CopyWithImpl$Variables$Mutation$EndStreamingSession(
    this._instance,
    this._then,
  );

  final Variables$Mutation$EndStreamingSession _instance;

  final TRes Function(Variables$Mutation$EndStreamingSession) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? sessionId = _undefined}) => _then(
        Variables$Mutation$EndStreamingSession._({
          ..._instance._$data,
          if (sessionId != _undefined && sessionId != null)
            'sessionId': (sessionId as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$EndStreamingSession<TRes>
    implements CopyWith$Variables$Mutation$EndStreamingSession<TRes> {
  _CopyWithStubImpl$Variables$Mutation$EndStreamingSession(this._res);

  TRes _res;

  call({String? sessionId}) => _res;
}

class Mutation$EndStreamingSession {
  Mutation$EndStreamingSession({
    this.endStreamingSession,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$EndStreamingSession.fromJson(Map<String, dynamic> json) {
    final l$endStreamingSession = json['endStreamingSession'];
    final l$$__typename = json['__typename'];
    return Mutation$EndStreamingSession(
      endStreamingSession: (l$endStreamingSession as bool?),
      $__typename: (l$$__typename as String),
    );
  }

  final bool? endStreamingSession;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$endStreamingSession = endStreamingSession;
    _resultData['endStreamingSession'] = l$endStreamingSession;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$endStreamingSession = endStreamingSession;
    final l$$__typename = $__typename;
    return Object.hashAll([l$endStreamingSession, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$EndStreamingSession ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$endStreamingSession = endStreamingSession;
    final lOther$endStreamingSession = other.endStreamingSession;
    if (l$endStreamingSession != lOther$endStreamingSession) {
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

extension UtilityExtension$Mutation$EndStreamingSession
    on Mutation$EndStreamingSession {
  CopyWith$Mutation$EndStreamingSession<Mutation$EndStreamingSession>
      get copyWith => CopyWith$Mutation$EndStreamingSession(this, (i) => i);
}

abstract class CopyWith$Mutation$EndStreamingSession<TRes> {
  factory CopyWith$Mutation$EndStreamingSession(
    Mutation$EndStreamingSession instance,
    TRes Function(Mutation$EndStreamingSession) then,
  ) = _CopyWithImpl$Mutation$EndStreamingSession;

  factory CopyWith$Mutation$EndStreamingSession.stub(TRes res) =
      _CopyWithStubImpl$Mutation$EndStreamingSession;

  TRes call({bool? endStreamingSession, String? $__typename});
}

class _CopyWithImpl$Mutation$EndStreamingSession<TRes>
    implements CopyWith$Mutation$EndStreamingSession<TRes> {
  _CopyWithImpl$Mutation$EndStreamingSession(this._instance, this._then);

  final Mutation$EndStreamingSession _instance;

  final TRes Function(Mutation$EndStreamingSession) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? endStreamingSession = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$EndStreamingSession(
          endStreamingSession: endStreamingSession == _undefined
              ? _instance.endStreamingSession
              : (endStreamingSession as bool?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$EndStreamingSession<TRes>
    implements CopyWith$Mutation$EndStreamingSession<TRes> {
  _CopyWithStubImpl$Mutation$EndStreamingSession(this._res);

  TRes _res;

  call({bool? endStreamingSession, String? $__typename}) => _res;
}

const documentNodeMutationEndStreamingSession = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'EndStreamingSession'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'sessionId')),
          type: NamedTypeNode(name: NameNode(value: 'String'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'endStreamingSession'),
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
