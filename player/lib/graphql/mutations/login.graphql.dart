import 'package:gql/ast.dart';

class Variables$Mutation$Login {
  factory Variables$Mutation$Login({
    required String username,
    required String password,
    required String deviceId,
    required String deviceName,
    required String platform,
  }) =>
      Variables$Mutation$Login._({
        r'username': username,
        r'password': password,
        r'deviceId': deviceId,
        r'deviceName': deviceName,
        r'platform': platform,
      });

  Variables$Mutation$Login._(this._$data);

  factory Variables$Mutation$Login.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    final l$username = data['username'];
    result$data['username'] = (l$username as String);
    final l$password = data['password'];
    result$data['password'] = (l$password as String);
    final l$deviceId = data['deviceId'];
    result$data['deviceId'] = (l$deviceId as String);
    final l$deviceName = data['deviceName'];
    result$data['deviceName'] = (l$deviceName as String);
    final l$platform = data['platform'];
    result$data['platform'] = (l$platform as String);
    return Variables$Mutation$Login._(result$data);
  }

  Map<String, dynamic> _$data;

  String get username => (_$data['username'] as String);

  String get password => (_$data['password'] as String);

  String get deviceId => (_$data['deviceId'] as String);

  String get deviceName => (_$data['deviceName'] as String);

  String get platform => (_$data['platform'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$username = username;
    result$data['username'] = l$username;
    final l$password = password;
    result$data['password'] = l$password;
    final l$deviceId = deviceId;
    result$data['deviceId'] = l$deviceId;
    final l$deviceName = deviceName;
    result$data['deviceName'] = l$deviceName;
    final l$platform = platform;
    result$data['platform'] = l$platform;
    return result$data;
  }

  CopyWith$Variables$Mutation$Login<Variables$Mutation$Login> get copyWith =>
      CopyWith$Variables$Mutation$Login(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$Login ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$username = username;
    final lOther$username = other.username;
    if (l$username != lOther$username) {
      return false;
    }
    final l$password = password;
    final lOther$password = other.password;
    if (l$password != lOther$password) {
      return false;
    }
    final l$deviceId = deviceId;
    final lOther$deviceId = other.deviceId;
    if (l$deviceId != lOther$deviceId) {
      return false;
    }
    final l$deviceName = deviceName;
    final lOther$deviceName = other.deviceName;
    if (l$deviceName != lOther$deviceName) {
      return false;
    }
    final l$platform = platform;
    final lOther$platform = other.platform;
    if (l$platform != lOther$platform) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$username = username;
    final l$password = password;
    final l$deviceId = deviceId;
    final l$deviceName = deviceName;
    final l$platform = platform;
    return Object.hashAll([
      l$username,
      l$password,
      l$deviceId,
      l$deviceName,
      l$platform,
    ]);
  }
}

abstract class CopyWith$Variables$Mutation$Login<TRes> {
  factory CopyWith$Variables$Mutation$Login(
    Variables$Mutation$Login instance,
    TRes Function(Variables$Mutation$Login) then,
  ) = _CopyWithImpl$Variables$Mutation$Login;

  factory CopyWith$Variables$Mutation$Login.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$Login;

  TRes call({
    String? username,
    String? password,
    String? deviceId,
    String? deviceName,
    String? platform,
  });
}

class _CopyWithImpl$Variables$Mutation$Login<TRes>
    implements CopyWith$Variables$Mutation$Login<TRes> {
  _CopyWithImpl$Variables$Mutation$Login(this._instance, this._then);

  final Variables$Mutation$Login _instance;

  final TRes Function(Variables$Mutation$Login) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? username = _undefined,
    Object? password = _undefined,
    Object? deviceId = _undefined,
    Object? deviceName = _undefined,
    Object? platform = _undefined,
  }) =>
      _then(
        Variables$Mutation$Login._({
          ..._instance._$data,
          if (username != _undefined && username != null)
            'username': (username as String),
          if (password != _undefined && password != null)
            'password': (password as String),
          if (deviceId != _undefined && deviceId != null)
            'deviceId': (deviceId as String),
          if (deviceName != _undefined && deviceName != null)
            'deviceName': (deviceName as String),
          if (platform != _undefined && platform != null)
            'platform': (platform as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$Login<TRes>
    implements CopyWith$Variables$Mutation$Login<TRes> {
  _CopyWithStubImpl$Variables$Mutation$Login(this._res);

  TRes _res;

  call({
    String? username,
    String? password,
    String? deviceId,
    String? deviceName,
    String? platform,
  }) =>
      _res;
}

class Mutation$Login {
  Mutation$Login({this.login, this.$__typename = 'RootMutationType'});

  factory Mutation$Login.fromJson(Map<String, dynamic> json) {
    final l$login = json['login'];
    final l$$__typename = json['__typename'];
    return Mutation$Login(
      login: l$login == null
          ? null
          : Mutation$Login$login.fromJson((l$login as Map<String, dynamic>)),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$Login$login? login;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$login = login;
    _resultData['login'] = l$login?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$login = login;
    final l$$__typename = $__typename;
    return Object.hashAll([l$login, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$Login || runtimeType != other.runtimeType) {
      return false;
    }
    final l$login = login;
    final lOther$login = other.login;
    if (l$login != lOther$login) {
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

extension UtilityExtension$Mutation$Login on Mutation$Login {
  CopyWith$Mutation$Login<Mutation$Login> get copyWith =>
      CopyWith$Mutation$Login(this, (i) => i);
}

abstract class CopyWith$Mutation$Login<TRes> {
  factory CopyWith$Mutation$Login(
    Mutation$Login instance,
    TRes Function(Mutation$Login) then,
  ) = _CopyWithImpl$Mutation$Login;

  factory CopyWith$Mutation$Login.stub(TRes res) =
      _CopyWithStubImpl$Mutation$Login;

  TRes call({Mutation$Login$login? login, String? $__typename});
  CopyWith$Mutation$Login$login<TRes> get login;
}

class _CopyWithImpl$Mutation$Login<TRes>
    implements CopyWith$Mutation$Login<TRes> {
  _CopyWithImpl$Mutation$Login(this._instance, this._then);

  final Mutation$Login _instance;

  final TRes Function(Mutation$Login) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? login = _undefined, Object? $__typename = _undefined}) =>
      _then(
        Mutation$Login(
          login: login == _undefined
              ? _instance.login
              : (login as Mutation$Login$login?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$Login$login<TRes> get login {
    final local$login = _instance.login;
    return local$login == null
        ? CopyWith$Mutation$Login$login.stub(_then(_instance))
        : CopyWith$Mutation$Login$login(local$login, (e) => call(login: e));
  }
}

class _CopyWithStubImpl$Mutation$Login<TRes>
    implements CopyWith$Mutation$Login<TRes> {
  _CopyWithStubImpl$Mutation$Login(this._res);

  TRes _res;

  call({Mutation$Login$login? login, String? $__typename}) => _res;

  CopyWith$Mutation$Login$login<TRes> get login =>
      CopyWith$Mutation$Login$login.stub(_res);
}

const documentNodeMutationLogin = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'Login'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'username')),
          type: NamedTypeNode(name: NameNode(value: 'String'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'password')),
          type: NamedTypeNode(name: NameNode(value: 'String'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'deviceId')),
          type: NamedTypeNode(name: NameNode(value: 'String'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'deviceName')),
          type: NamedTypeNode(name: NameNode(value: 'String'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'platform')),
          type: NamedTypeNode(name: NameNode(value: 'String'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'login'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'input'),
                value: ObjectValueNode(
                  fields: [
                    ObjectFieldNode(
                      name: NameNode(value: 'username'),
                      value: VariableNode(name: NameNode(value: 'username')),
                    ),
                    ObjectFieldNode(
                      name: NameNode(value: 'password'),
                      value: VariableNode(name: NameNode(value: 'password')),
                    ),
                    ObjectFieldNode(
                      name: NameNode(value: 'deviceId'),
                      value: VariableNode(name: NameNode(value: 'deviceId')),
                    ),
                    ObjectFieldNode(
                      name: NameNode(value: 'deviceName'),
                      value: VariableNode(name: NameNode(value: 'deviceName')),
                    ),
                    ObjectFieldNode(
                      name: NameNode(value: 'platform'),
                      value: VariableNode(name: NameNode(value: 'platform')),
                    ),
                  ],
                ),
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
                  name: NameNode(value: 'user'),
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
                        name: NameNode(value: 'username'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'email'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'displayName'),
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
                  name: NameNode(value: 'expiresIn'),
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

class Mutation$Login$login {
  Mutation$Login$login({
    required this.token,
    required this.user,
    required this.expiresIn,
    this.$__typename = 'LoginResult',
  });

  factory Mutation$Login$login.fromJson(Map<String, dynamic> json) {
    final l$token = json['token'];
    final l$user = json['user'];
    final l$expiresIn = json['expiresIn'];
    final l$$__typename = json['__typename'];
    return Mutation$Login$login(
      token: (l$token as String),
      user: Mutation$Login$login$user.fromJson(
        (l$user as Map<String, dynamic>),
      ),
      expiresIn: (l$expiresIn as int),
      $__typename: (l$$__typename as String),
    );
  }

  final String token;

  final Mutation$Login$login$user user;

  final int expiresIn;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$token = token;
    _resultData['token'] = l$token;
    final l$user = user;
    _resultData['user'] = l$user.toJson();
    final l$expiresIn = expiresIn;
    _resultData['expiresIn'] = l$expiresIn;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$token = token;
    final l$user = user;
    final l$expiresIn = expiresIn;
    final l$$__typename = $__typename;
    return Object.hashAll([l$token, l$user, l$expiresIn, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$Login$login || runtimeType != other.runtimeType) {
      return false;
    }
    final l$token = token;
    final lOther$token = other.token;
    if (l$token != lOther$token) {
      return false;
    }
    final l$user = user;
    final lOther$user = other.user;
    if (l$user != lOther$user) {
      return false;
    }
    final l$expiresIn = expiresIn;
    final lOther$expiresIn = other.expiresIn;
    if (l$expiresIn != lOther$expiresIn) {
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

extension UtilityExtension$Mutation$Login$login on Mutation$Login$login {
  CopyWith$Mutation$Login$login<Mutation$Login$login> get copyWith =>
      CopyWith$Mutation$Login$login(this, (i) => i);
}

abstract class CopyWith$Mutation$Login$login<TRes> {
  factory CopyWith$Mutation$Login$login(
    Mutation$Login$login instance,
    TRes Function(Mutation$Login$login) then,
  ) = _CopyWithImpl$Mutation$Login$login;

  factory CopyWith$Mutation$Login$login.stub(TRes res) =
      _CopyWithStubImpl$Mutation$Login$login;

  TRes call({
    String? token,
    Mutation$Login$login$user? user,
    int? expiresIn,
    String? $__typename,
  });
  CopyWith$Mutation$Login$login$user<TRes> get user;
}

class _CopyWithImpl$Mutation$Login$login<TRes>
    implements CopyWith$Mutation$Login$login<TRes> {
  _CopyWithImpl$Mutation$Login$login(this._instance, this._then);

  final Mutation$Login$login _instance;

  final TRes Function(Mutation$Login$login) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? token = _undefined,
    Object? user = _undefined,
    Object? expiresIn = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$Login$login(
          token: token == _undefined || token == null
              ? _instance.token
              : (token as String),
          user: user == _undefined || user == null
              ? _instance.user
              : (user as Mutation$Login$login$user),
          expiresIn: expiresIn == _undefined || expiresIn == null
              ? _instance.expiresIn
              : (expiresIn as int),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$Login$login$user<TRes> get user {
    final local$user = _instance.user;
    return CopyWith$Mutation$Login$login$user(local$user, (e) => call(user: e));
  }
}

class _CopyWithStubImpl$Mutation$Login$login<TRes>
    implements CopyWith$Mutation$Login$login<TRes> {
  _CopyWithStubImpl$Mutation$Login$login(this._res);

  TRes _res;

  call({
    String? token,
    Mutation$Login$login$user? user,
    int? expiresIn,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$Login$login$user<TRes> get user =>
      CopyWith$Mutation$Login$login$user.stub(_res);
}

class Mutation$Login$login$user {
  Mutation$Login$login$user({
    required this.id,
    this.username,
    this.email,
    this.displayName,
    this.$__typename = 'User',
  });

  factory Mutation$Login$login$user.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$username = json['username'];
    final l$email = json['email'];
    final l$displayName = json['displayName'];
    final l$$__typename = json['__typename'];
    return Mutation$Login$login$user(
      id: (l$id as String),
      username: (l$username as String?),
      email: (l$email as String?),
      displayName: (l$displayName as String?),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String? username;

  final String? email;

  final String? displayName;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$username = username;
    _resultData['username'] = l$username;
    final l$email = email;
    _resultData['email'] = l$email;
    final l$displayName = displayName;
    _resultData['displayName'] = l$displayName;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$username = username;
    final l$email = email;
    final l$displayName = displayName;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$username,
      l$email,
      l$displayName,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$Login$login$user ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$username = username;
    final lOther$username = other.username;
    if (l$username != lOther$username) {
      return false;
    }
    final l$email = email;
    final lOther$email = other.email;
    if (l$email != lOther$email) {
      return false;
    }
    final l$displayName = displayName;
    final lOther$displayName = other.displayName;
    if (l$displayName != lOther$displayName) {
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

extension UtilityExtension$Mutation$Login$login$user
    on Mutation$Login$login$user {
  CopyWith$Mutation$Login$login$user<Mutation$Login$login$user> get copyWith =>
      CopyWith$Mutation$Login$login$user(this, (i) => i);
}

abstract class CopyWith$Mutation$Login$login$user<TRes> {
  factory CopyWith$Mutation$Login$login$user(
    Mutation$Login$login$user instance,
    TRes Function(Mutation$Login$login$user) then,
  ) = _CopyWithImpl$Mutation$Login$login$user;

  factory CopyWith$Mutation$Login$login$user.stub(TRes res) =
      _CopyWithStubImpl$Mutation$Login$login$user;

  TRes call({
    String? id,
    String? username,
    String? email,
    String? displayName,
    String? $__typename,
  });
}

class _CopyWithImpl$Mutation$Login$login$user<TRes>
    implements CopyWith$Mutation$Login$login$user<TRes> {
  _CopyWithImpl$Mutation$Login$login$user(this._instance, this._then);

  final Mutation$Login$login$user _instance;

  final TRes Function(Mutation$Login$login$user) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? username = _undefined,
    Object? email = _undefined,
    Object? displayName = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$Login$login$user(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          username: username == _undefined
              ? _instance.username
              : (username as String?),
          email: email == _undefined ? _instance.email : (email as String?),
          displayName: displayName == _undefined
              ? _instance.displayName
              : (displayName as String?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$Login$login$user<TRes>
    implements CopyWith$Mutation$Login$login$user<TRes> {
  _CopyWithStubImpl$Mutation$Login$login$user(this._res);

  TRes _res;

  call({
    String? id,
    String? username,
    String? email,
    String? displayName,
    String? $__typename,
  }) =>
      _res;
}
