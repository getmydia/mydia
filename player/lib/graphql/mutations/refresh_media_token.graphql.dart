import 'package:gql/ast.dart';

class Variables$Mutation$RefreshMediaToken {
  factory Variables$Mutation$RefreshMediaToken({required String token}) =>
      Variables$Mutation$RefreshMediaToken._({r'token': token});

  Variables$Mutation$RefreshMediaToken._(this._$data);

  factory Variables$Mutation$RefreshMediaToken.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$token = data['token'];
    result$data['token'] = (l$token as String);
    return Variables$Mutation$RefreshMediaToken._(result$data);
  }

  Map<String, dynamic> _$data;

  String get token => (_$data['token'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$token = token;
    result$data['token'] = l$token;
    return result$data;
  }

  CopyWith$Variables$Mutation$RefreshMediaToken<
          Variables$Mutation$RefreshMediaToken>
      get copyWith =>
          CopyWith$Variables$Mutation$RefreshMediaToken(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$RefreshMediaToken ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$token = token;
    final lOther$token = other.token;
    if (l$token != lOther$token) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$token = token;
    return Object.hashAll([l$token]);
  }
}

abstract class CopyWith$Variables$Mutation$RefreshMediaToken<TRes> {
  factory CopyWith$Variables$Mutation$RefreshMediaToken(
    Variables$Mutation$RefreshMediaToken instance,
    TRes Function(Variables$Mutation$RefreshMediaToken) then,
  ) = _CopyWithImpl$Variables$Mutation$RefreshMediaToken;

  factory CopyWith$Variables$Mutation$RefreshMediaToken.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$RefreshMediaToken;

  TRes call({String? token});
}

class _CopyWithImpl$Variables$Mutation$RefreshMediaToken<TRes>
    implements CopyWith$Variables$Mutation$RefreshMediaToken<TRes> {
  _CopyWithImpl$Variables$Mutation$RefreshMediaToken(
    this._instance,
    this._then,
  );

  final Variables$Mutation$RefreshMediaToken _instance;

  final TRes Function(Variables$Mutation$RefreshMediaToken) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? token = _undefined}) => _then(
        Variables$Mutation$RefreshMediaToken._({
          ..._instance._$data,
          if (token != _undefined && token != null) 'token': (token as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$RefreshMediaToken<TRes>
    implements CopyWith$Variables$Mutation$RefreshMediaToken<TRes> {
  _CopyWithStubImpl$Variables$Mutation$RefreshMediaToken(this._res);

  TRes _res;

  call({String? token}) => _res;
}

class Mutation$RefreshMediaToken {
  Mutation$RefreshMediaToken({
    this.refreshMediaToken,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$RefreshMediaToken.fromJson(Map<String, dynamic> json) {
    final l$refreshMediaToken = json['refreshMediaToken'];
    final l$$__typename = json['__typename'];
    return Mutation$RefreshMediaToken(
      refreshMediaToken: l$refreshMediaToken == null
          ? null
          : Mutation$RefreshMediaToken$refreshMediaToken.fromJson(
              (l$refreshMediaToken as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$RefreshMediaToken$refreshMediaToken? refreshMediaToken;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$refreshMediaToken = refreshMediaToken;
    _resultData['refreshMediaToken'] = l$refreshMediaToken?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$refreshMediaToken = refreshMediaToken;
    final l$$__typename = $__typename;
    return Object.hashAll([l$refreshMediaToken, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$RefreshMediaToken ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$refreshMediaToken = refreshMediaToken;
    final lOther$refreshMediaToken = other.refreshMediaToken;
    if (l$refreshMediaToken != lOther$refreshMediaToken) {
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

extension UtilityExtension$Mutation$RefreshMediaToken
    on Mutation$RefreshMediaToken {
  CopyWith$Mutation$RefreshMediaToken<Mutation$RefreshMediaToken>
      get copyWith => CopyWith$Mutation$RefreshMediaToken(this, (i) => i);
}

abstract class CopyWith$Mutation$RefreshMediaToken<TRes> {
  factory CopyWith$Mutation$RefreshMediaToken(
    Mutation$RefreshMediaToken instance,
    TRes Function(Mutation$RefreshMediaToken) then,
  ) = _CopyWithImpl$Mutation$RefreshMediaToken;

  factory CopyWith$Mutation$RefreshMediaToken.stub(TRes res) =
      _CopyWithStubImpl$Mutation$RefreshMediaToken;

  TRes call({
    Mutation$RefreshMediaToken$refreshMediaToken? refreshMediaToken,
    String? $__typename,
  });
  CopyWith$Mutation$RefreshMediaToken$refreshMediaToken<TRes>
      get refreshMediaToken;
}

class _CopyWithImpl$Mutation$RefreshMediaToken<TRes>
    implements CopyWith$Mutation$RefreshMediaToken<TRes> {
  _CopyWithImpl$Mutation$RefreshMediaToken(this._instance, this._then);

  final Mutation$RefreshMediaToken _instance;

  final TRes Function(Mutation$RefreshMediaToken) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? refreshMediaToken = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$RefreshMediaToken(
          refreshMediaToken: refreshMediaToken == _undefined
              ? _instance.refreshMediaToken
              : (refreshMediaToken
                  as Mutation$RefreshMediaToken$refreshMediaToken?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$RefreshMediaToken$refreshMediaToken<TRes>
      get refreshMediaToken {
    final local$refreshMediaToken = _instance.refreshMediaToken;
    return local$refreshMediaToken == null
        ? CopyWith$Mutation$RefreshMediaToken$refreshMediaToken.stub(
            _then(_instance),
          )
        : CopyWith$Mutation$RefreshMediaToken$refreshMediaToken(
            local$refreshMediaToken,
            (e) => call(refreshMediaToken: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$RefreshMediaToken<TRes>
    implements CopyWith$Mutation$RefreshMediaToken<TRes> {
  _CopyWithStubImpl$Mutation$RefreshMediaToken(this._res);

  TRes _res;

  call({
    Mutation$RefreshMediaToken$refreshMediaToken? refreshMediaToken,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$RefreshMediaToken$refreshMediaToken<TRes>
      get refreshMediaToken =>
          CopyWith$Mutation$RefreshMediaToken$refreshMediaToken.stub(_res);
}

const documentNodeMutationRefreshMediaToken = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'RefreshMediaToken'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'token')),
          type: NamedTypeNode(name: NameNode(value: 'String'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'refreshMediaToken'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'token'),
                value: VariableNode(name: NameNode(value: 'token')),
              ),
            ],
            directives: [],
            selectionSet: SelectionSetNode(
              selections: [
                FieldNode(
                  name: NameNode(value: 'token'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'expiresAt'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'permissions'),
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

class Mutation$RefreshMediaToken$refreshMediaToken {
  Mutation$RefreshMediaToken$refreshMediaToken({
    required this.token,
    required this.expiresAt,
    required this.permissions,
    this.$__typename = 'MediaToken',
  });

  factory Mutation$RefreshMediaToken$refreshMediaToken.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$token = json['token'];
    final l$expiresAt = json['expiresAt'];
    final l$permissions = json['permissions'];
    final l$$__typename = json['__typename'];
    return Mutation$RefreshMediaToken$refreshMediaToken(
      token: (l$token as String),
      expiresAt: (l$expiresAt as String),
      permissions:
          (l$permissions as List<dynamic>).map((e) => (e as String)).toList(),
      $__typename: (l$$__typename as String),
    );
  }

  final String token;

  final String expiresAt;

  final List<String> permissions;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$token = token;
    _resultData['token'] = l$token;
    final l$expiresAt = expiresAt;
    _resultData['expiresAt'] = l$expiresAt;
    final l$permissions = permissions;
    _resultData['permissions'] = l$permissions.map((e) => e).toList();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$token = token;
    final l$expiresAt = expiresAt;
    final l$permissions = permissions;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$token,
      l$expiresAt,
      Object.hashAll(l$permissions.map((v) => v)),
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$RefreshMediaToken$refreshMediaToken ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$token = token;
    final lOther$token = other.token;
    if (l$token != lOther$token) {
      return false;
    }
    final l$expiresAt = expiresAt;
    final lOther$expiresAt = other.expiresAt;
    if (l$expiresAt != lOther$expiresAt) {
      return false;
    }
    final l$permissions = permissions;
    final lOther$permissions = other.permissions;
    if (l$permissions.length != lOther$permissions.length) {
      return false;
    }
    for (int i = 0; i < l$permissions.length; i++) {
      final l$permissions$entry = l$permissions[i];
      final lOther$permissions$entry = lOther$permissions[i];
      if (l$permissions$entry != lOther$permissions$entry) {
        return false;
      }
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Mutation$RefreshMediaToken$refreshMediaToken
    on Mutation$RefreshMediaToken$refreshMediaToken {
  CopyWith$Mutation$RefreshMediaToken$refreshMediaToken<
          Mutation$RefreshMediaToken$refreshMediaToken>
      get copyWith =>
          CopyWith$Mutation$RefreshMediaToken$refreshMediaToken(this, (i) => i);
}

abstract class CopyWith$Mutation$RefreshMediaToken$refreshMediaToken<TRes> {
  factory CopyWith$Mutation$RefreshMediaToken$refreshMediaToken(
    Mutation$RefreshMediaToken$refreshMediaToken instance,
    TRes Function(Mutation$RefreshMediaToken$refreshMediaToken) then,
  ) = _CopyWithImpl$Mutation$RefreshMediaToken$refreshMediaToken;

  factory CopyWith$Mutation$RefreshMediaToken$refreshMediaToken.stub(TRes res) =
      _CopyWithStubImpl$Mutation$RefreshMediaToken$refreshMediaToken;

  TRes call({
    String? token,
    String? expiresAt,
    List<String>? permissions,
    String? $__typename,
  });
}

class _CopyWithImpl$Mutation$RefreshMediaToken$refreshMediaToken<TRes>
    implements CopyWith$Mutation$RefreshMediaToken$refreshMediaToken<TRes> {
  _CopyWithImpl$Mutation$RefreshMediaToken$refreshMediaToken(
    this._instance,
    this._then,
  );

  final Mutation$RefreshMediaToken$refreshMediaToken _instance;

  final TRes Function(Mutation$RefreshMediaToken$refreshMediaToken) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? token = _undefined,
    Object? expiresAt = _undefined,
    Object? permissions = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$RefreshMediaToken$refreshMediaToken(
          token: token == _undefined || token == null
              ? _instance.token
              : (token as String),
          expiresAt: expiresAt == _undefined || expiresAt == null
              ? _instance.expiresAt
              : (expiresAt as String),
          permissions: permissions == _undefined || permissions == null
              ? _instance.permissions
              : (permissions as List<String>),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$RefreshMediaToken$refreshMediaToken<TRes>
    implements CopyWith$Mutation$RefreshMediaToken$refreshMediaToken<TRes> {
  _CopyWithStubImpl$Mutation$RefreshMediaToken$refreshMediaToken(this._res);

  TRes _res;

  call({
    String? token,
    String? expiresAt,
    List<String>? permissions,
    String? $__typename,
  }) =>
      _res;
}
