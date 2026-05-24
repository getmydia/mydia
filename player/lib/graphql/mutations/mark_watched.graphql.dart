import 'package:gql/ast.dart';

class Variables$Mutation$MarkMovieWatched {
  factory Variables$Mutation$MarkMovieWatched({required String movieId}) =>
      Variables$Mutation$MarkMovieWatched._({r'movieId': movieId});

  Variables$Mutation$MarkMovieWatched._(this._$data);

  factory Variables$Mutation$MarkMovieWatched.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$movieId = data['movieId'];
    result$data['movieId'] = (l$movieId as String);
    return Variables$Mutation$MarkMovieWatched._(result$data);
  }

  Map<String, dynamic> _$data;

  String get movieId => (_$data['movieId'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$movieId = movieId;
    result$data['movieId'] = l$movieId;
    return result$data;
  }

  CopyWith$Variables$Mutation$MarkMovieWatched<
          Variables$Mutation$MarkMovieWatched>
      get copyWith =>
          CopyWith$Variables$Mutation$MarkMovieWatched(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$MarkMovieWatched ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$movieId = movieId;
    final lOther$movieId = other.movieId;
    if (l$movieId != lOther$movieId) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$movieId = movieId;
    return Object.hashAll([l$movieId]);
  }
}

abstract class CopyWith$Variables$Mutation$MarkMovieWatched<TRes> {
  factory CopyWith$Variables$Mutation$MarkMovieWatched(
    Variables$Mutation$MarkMovieWatched instance,
    TRes Function(Variables$Mutation$MarkMovieWatched) then,
  ) = _CopyWithImpl$Variables$Mutation$MarkMovieWatched;

  factory CopyWith$Variables$Mutation$MarkMovieWatched.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$MarkMovieWatched;

  TRes call({String? movieId});
}

class _CopyWithImpl$Variables$Mutation$MarkMovieWatched<TRes>
    implements CopyWith$Variables$Mutation$MarkMovieWatched<TRes> {
  _CopyWithImpl$Variables$Mutation$MarkMovieWatched(this._instance, this._then);

  final Variables$Mutation$MarkMovieWatched _instance;

  final TRes Function(Variables$Mutation$MarkMovieWatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? movieId = _undefined}) => _then(
        Variables$Mutation$MarkMovieWatched._({
          ..._instance._$data,
          if (movieId != _undefined && movieId != null)
            'movieId': (movieId as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$MarkMovieWatched<TRes>
    implements CopyWith$Variables$Mutation$MarkMovieWatched<TRes> {
  _CopyWithStubImpl$Variables$Mutation$MarkMovieWatched(this._res);

  TRes _res;

  call({String? movieId}) => _res;
}

class Mutation$MarkMovieWatched {
  Mutation$MarkMovieWatched({
    this.markMovieWatched,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$MarkMovieWatched.fromJson(Map<String, dynamic> json) {
    final l$markMovieWatched = json['markMovieWatched'];
    final l$$__typename = json['__typename'];
    return Mutation$MarkMovieWatched(
      markMovieWatched: l$markMovieWatched == null
          ? null
          : Mutation$MarkMovieWatched$markMovieWatched.fromJson(
              (l$markMovieWatched as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$MarkMovieWatched$markMovieWatched? markMovieWatched;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$markMovieWatched = markMovieWatched;
    _resultData['markMovieWatched'] = l$markMovieWatched?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$markMovieWatched = markMovieWatched;
    final l$$__typename = $__typename;
    return Object.hashAll([l$markMovieWatched, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$MarkMovieWatched ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$markMovieWatched = markMovieWatched;
    final lOther$markMovieWatched = other.markMovieWatched;
    if (l$markMovieWatched != lOther$markMovieWatched) {
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

extension UtilityExtension$Mutation$MarkMovieWatched
    on Mutation$MarkMovieWatched {
  CopyWith$Mutation$MarkMovieWatched<Mutation$MarkMovieWatched> get copyWith =>
      CopyWith$Mutation$MarkMovieWatched(this, (i) => i);
}

abstract class CopyWith$Mutation$MarkMovieWatched<TRes> {
  factory CopyWith$Mutation$MarkMovieWatched(
    Mutation$MarkMovieWatched instance,
    TRes Function(Mutation$MarkMovieWatched) then,
  ) = _CopyWithImpl$Mutation$MarkMovieWatched;

  factory CopyWith$Mutation$MarkMovieWatched.stub(TRes res) =
      _CopyWithStubImpl$Mutation$MarkMovieWatched;

  TRes call({
    Mutation$MarkMovieWatched$markMovieWatched? markMovieWatched,
    String? $__typename,
  });
  CopyWith$Mutation$MarkMovieWatched$markMovieWatched<TRes>
      get markMovieWatched;
}

class _CopyWithImpl$Mutation$MarkMovieWatched<TRes>
    implements CopyWith$Mutation$MarkMovieWatched<TRes> {
  _CopyWithImpl$Mutation$MarkMovieWatched(this._instance, this._then);

  final Mutation$MarkMovieWatched _instance;

  final TRes Function(Mutation$MarkMovieWatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? markMovieWatched = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$MarkMovieWatched(
          markMovieWatched: markMovieWatched == _undefined
              ? _instance.markMovieWatched
              : (markMovieWatched
                  as Mutation$MarkMovieWatched$markMovieWatched?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$MarkMovieWatched$markMovieWatched<TRes>
      get markMovieWatched {
    final local$markMovieWatched = _instance.markMovieWatched;
    return local$markMovieWatched == null
        ? CopyWith$Mutation$MarkMovieWatched$markMovieWatched.stub(
            _then(_instance),
          )
        : CopyWith$Mutation$MarkMovieWatched$markMovieWatched(
            local$markMovieWatched,
            (e) => call(markMovieWatched: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$MarkMovieWatched<TRes>
    implements CopyWith$Mutation$MarkMovieWatched<TRes> {
  _CopyWithStubImpl$Mutation$MarkMovieWatched(this._res);

  TRes _res;

  call({
    Mutation$MarkMovieWatched$markMovieWatched? markMovieWatched,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$MarkMovieWatched$markMovieWatched<TRes>
      get markMovieWatched =>
          CopyWith$Mutation$MarkMovieWatched$markMovieWatched.stub(_res);
}

const documentNodeMutationMarkMovieWatched = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'MarkMovieWatched'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'movieId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'markMovieWatched'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'movieId'),
                value: VariableNode(name: NameNode(value: 'movieId')),
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

class Mutation$MarkMovieWatched$markMovieWatched {
  Mutation$MarkMovieWatched$markMovieWatched({
    required this.id,
    required this.title,
    this.$__typename = 'Movie',
  });

  factory Mutation$MarkMovieWatched$markMovieWatched.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$title = json['title'];
    final l$$__typename = json['__typename'];
    return Mutation$MarkMovieWatched$markMovieWatched(
      id: (l$id as String),
      title: (l$title as String),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String title;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$title = title;
    final l$$__typename = $__typename;
    return Object.hashAll([l$id, l$title, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$MarkMovieWatched$markMovieWatched ||
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
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Mutation$MarkMovieWatched$markMovieWatched
    on Mutation$MarkMovieWatched$markMovieWatched {
  CopyWith$Mutation$MarkMovieWatched$markMovieWatched<
          Mutation$MarkMovieWatched$markMovieWatched>
      get copyWith =>
          CopyWith$Mutation$MarkMovieWatched$markMovieWatched(this, (i) => i);
}

abstract class CopyWith$Mutation$MarkMovieWatched$markMovieWatched<TRes> {
  factory CopyWith$Mutation$MarkMovieWatched$markMovieWatched(
    Mutation$MarkMovieWatched$markMovieWatched instance,
    TRes Function(Mutation$MarkMovieWatched$markMovieWatched) then,
  ) = _CopyWithImpl$Mutation$MarkMovieWatched$markMovieWatched;

  factory CopyWith$Mutation$MarkMovieWatched$markMovieWatched.stub(TRes res) =
      _CopyWithStubImpl$Mutation$MarkMovieWatched$markMovieWatched;

  TRes call({String? id, String? title, String? $__typename});
}

class _CopyWithImpl$Mutation$MarkMovieWatched$markMovieWatched<TRes>
    implements CopyWith$Mutation$MarkMovieWatched$markMovieWatched<TRes> {
  _CopyWithImpl$Mutation$MarkMovieWatched$markMovieWatched(
    this._instance,
    this._then,
  );

  final Mutation$MarkMovieWatched$markMovieWatched _instance;

  final TRes Function(Mutation$MarkMovieWatched$markMovieWatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? title = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$MarkMovieWatched$markMovieWatched(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          title: title == _undefined || title == null
              ? _instance.title
              : (title as String),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$MarkMovieWatched$markMovieWatched<TRes>
    implements CopyWith$Mutation$MarkMovieWatched$markMovieWatched<TRes> {
  _CopyWithStubImpl$Mutation$MarkMovieWatched$markMovieWatched(this._res);

  TRes _res;

  call({String? id, String? title, String? $__typename}) => _res;
}

class Variables$Mutation$MarkMovieUnwatched {
  factory Variables$Mutation$MarkMovieUnwatched({required String movieId}) =>
      Variables$Mutation$MarkMovieUnwatched._({r'movieId': movieId});

  Variables$Mutation$MarkMovieUnwatched._(this._$data);

  factory Variables$Mutation$MarkMovieUnwatched.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$movieId = data['movieId'];
    result$data['movieId'] = (l$movieId as String);
    return Variables$Mutation$MarkMovieUnwatched._(result$data);
  }

  Map<String, dynamic> _$data;

  String get movieId => (_$data['movieId'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$movieId = movieId;
    result$data['movieId'] = l$movieId;
    return result$data;
  }

  CopyWith$Variables$Mutation$MarkMovieUnwatched<
          Variables$Mutation$MarkMovieUnwatched>
      get copyWith =>
          CopyWith$Variables$Mutation$MarkMovieUnwatched(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$MarkMovieUnwatched ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$movieId = movieId;
    final lOther$movieId = other.movieId;
    if (l$movieId != lOther$movieId) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$movieId = movieId;
    return Object.hashAll([l$movieId]);
  }
}

abstract class CopyWith$Variables$Mutation$MarkMovieUnwatched<TRes> {
  factory CopyWith$Variables$Mutation$MarkMovieUnwatched(
    Variables$Mutation$MarkMovieUnwatched instance,
    TRes Function(Variables$Mutation$MarkMovieUnwatched) then,
  ) = _CopyWithImpl$Variables$Mutation$MarkMovieUnwatched;

  factory CopyWith$Variables$Mutation$MarkMovieUnwatched.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$MarkMovieUnwatched;

  TRes call({String? movieId});
}

class _CopyWithImpl$Variables$Mutation$MarkMovieUnwatched<TRes>
    implements CopyWith$Variables$Mutation$MarkMovieUnwatched<TRes> {
  _CopyWithImpl$Variables$Mutation$MarkMovieUnwatched(
    this._instance,
    this._then,
  );

  final Variables$Mutation$MarkMovieUnwatched _instance;

  final TRes Function(Variables$Mutation$MarkMovieUnwatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? movieId = _undefined}) => _then(
        Variables$Mutation$MarkMovieUnwatched._({
          ..._instance._$data,
          if (movieId != _undefined && movieId != null)
            'movieId': (movieId as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$MarkMovieUnwatched<TRes>
    implements CopyWith$Variables$Mutation$MarkMovieUnwatched<TRes> {
  _CopyWithStubImpl$Variables$Mutation$MarkMovieUnwatched(this._res);

  TRes _res;

  call({String? movieId}) => _res;
}

class Mutation$MarkMovieUnwatched {
  Mutation$MarkMovieUnwatched({
    this.markMovieUnwatched,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$MarkMovieUnwatched.fromJson(Map<String, dynamic> json) {
    final l$markMovieUnwatched = json['markMovieUnwatched'];
    final l$$__typename = json['__typename'];
    return Mutation$MarkMovieUnwatched(
      markMovieUnwatched: l$markMovieUnwatched == null
          ? null
          : Mutation$MarkMovieUnwatched$markMovieUnwatched.fromJson(
              (l$markMovieUnwatched as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$MarkMovieUnwatched$markMovieUnwatched? markMovieUnwatched;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$markMovieUnwatched = markMovieUnwatched;
    _resultData['markMovieUnwatched'] = l$markMovieUnwatched?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$markMovieUnwatched = markMovieUnwatched;
    final l$$__typename = $__typename;
    return Object.hashAll([l$markMovieUnwatched, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$MarkMovieUnwatched ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$markMovieUnwatched = markMovieUnwatched;
    final lOther$markMovieUnwatched = other.markMovieUnwatched;
    if (l$markMovieUnwatched != lOther$markMovieUnwatched) {
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

extension UtilityExtension$Mutation$MarkMovieUnwatched
    on Mutation$MarkMovieUnwatched {
  CopyWith$Mutation$MarkMovieUnwatched<Mutation$MarkMovieUnwatched>
      get copyWith => CopyWith$Mutation$MarkMovieUnwatched(this, (i) => i);
}

abstract class CopyWith$Mutation$MarkMovieUnwatched<TRes> {
  factory CopyWith$Mutation$MarkMovieUnwatched(
    Mutation$MarkMovieUnwatched instance,
    TRes Function(Mutation$MarkMovieUnwatched) then,
  ) = _CopyWithImpl$Mutation$MarkMovieUnwatched;

  factory CopyWith$Mutation$MarkMovieUnwatched.stub(TRes res) =
      _CopyWithStubImpl$Mutation$MarkMovieUnwatched;

  TRes call({
    Mutation$MarkMovieUnwatched$markMovieUnwatched? markMovieUnwatched,
    String? $__typename,
  });
  CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched<TRes>
      get markMovieUnwatched;
}

class _CopyWithImpl$Mutation$MarkMovieUnwatched<TRes>
    implements CopyWith$Mutation$MarkMovieUnwatched<TRes> {
  _CopyWithImpl$Mutation$MarkMovieUnwatched(this._instance, this._then);

  final Mutation$MarkMovieUnwatched _instance;

  final TRes Function(Mutation$MarkMovieUnwatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? markMovieUnwatched = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$MarkMovieUnwatched(
          markMovieUnwatched: markMovieUnwatched == _undefined
              ? _instance.markMovieUnwatched
              : (markMovieUnwatched
                  as Mutation$MarkMovieUnwatched$markMovieUnwatched?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched<TRes>
      get markMovieUnwatched {
    final local$markMovieUnwatched = _instance.markMovieUnwatched;
    return local$markMovieUnwatched == null
        ? CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched.stub(
            _then(_instance),
          )
        : CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched(
            local$markMovieUnwatched,
            (e) => call(markMovieUnwatched: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$MarkMovieUnwatched<TRes>
    implements CopyWith$Mutation$MarkMovieUnwatched<TRes> {
  _CopyWithStubImpl$Mutation$MarkMovieUnwatched(this._res);

  TRes _res;

  call({
    Mutation$MarkMovieUnwatched$markMovieUnwatched? markMovieUnwatched,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched<TRes>
      get markMovieUnwatched =>
          CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched.stub(_res);
}

const documentNodeMutationMarkMovieUnwatched = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'MarkMovieUnwatched'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'movieId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'markMovieUnwatched'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'movieId'),
                value: VariableNode(name: NameNode(value: 'movieId')),
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

class Mutation$MarkMovieUnwatched$markMovieUnwatched {
  Mutation$MarkMovieUnwatched$markMovieUnwatched({
    required this.id,
    required this.title,
    this.$__typename = 'Movie',
  });

  factory Mutation$MarkMovieUnwatched$markMovieUnwatched.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$title = json['title'];
    final l$$__typename = json['__typename'];
    return Mutation$MarkMovieUnwatched$markMovieUnwatched(
      id: (l$id as String),
      title: (l$title as String),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String title;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$title = title;
    final l$$__typename = $__typename;
    return Object.hashAll([l$id, l$title, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$MarkMovieUnwatched$markMovieUnwatched ||
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
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Mutation$MarkMovieUnwatched$markMovieUnwatched
    on Mutation$MarkMovieUnwatched$markMovieUnwatched {
  CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched<
          Mutation$MarkMovieUnwatched$markMovieUnwatched>
      get copyWith => CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched(
          this, (i) => i);
}

abstract class CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched<TRes> {
  factory CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched(
    Mutation$MarkMovieUnwatched$markMovieUnwatched instance,
    TRes Function(Mutation$MarkMovieUnwatched$markMovieUnwatched) then,
  ) = _CopyWithImpl$Mutation$MarkMovieUnwatched$markMovieUnwatched;

  factory CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched.stub(
    TRes res,
  ) = _CopyWithStubImpl$Mutation$MarkMovieUnwatched$markMovieUnwatched;

  TRes call({String? id, String? title, String? $__typename});
}

class _CopyWithImpl$Mutation$MarkMovieUnwatched$markMovieUnwatched<TRes>
    implements CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched<TRes> {
  _CopyWithImpl$Mutation$MarkMovieUnwatched$markMovieUnwatched(
    this._instance,
    this._then,
  );

  final Mutation$MarkMovieUnwatched$markMovieUnwatched _instance;

  final TRes Function(Mutation$MarkMovieUnwatched$markMovieUnwatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? title = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$MarkMovieUnwatched$markMovieUnwatched(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          title: title == _undefined || title == null
              ? _instance.title
              : (title as String),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$MarkMovieUnwatched$markMovieUnwatched<TRes>
    implements CopyWith$Mutation$MarkMovieUnwatched$markMovieUnwatched<TRes> {
  _CopyWithStubImpl$Mutation$MarkMovieUnwatched$markMovieUnwatched(this._res);

  TRes _res;

  call({String? id, String? title, String? $__typename}) => _res;
}

class Variables$Mutation$MarkEpisodeWatched {
  factory Variables$Mutation$MarkEpisodeWatched({required String episodeId}) =>
      Variables$Mutation$MarkEpisodeWatched._({r'episodeId': episodeId});

  Variables$Mutation$MarkEpisodeWatched._(this._$data);

  factory Variables$Mutation$MarkEpisodeWatched.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$episodeId = data['episodeId'];
    result$data['episodeId'] = (l$episodeId as String);
    return Variables$Mutation$MarkEpisodeWatched._(result$data);
  }

  Map<String, dynamic> _$data;

  String get episodeId => (_$data['episodeId'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$episodeId = episodeId;
    result$data['episodeId'] = l$episodeId;
    return result$data;
  }

  CopyWith$Variables$Mutation$MarkEpisodeWatched<
          Variables$Mutation$MarkEpisodeWatched>
      get copyWith =>
          CopyWith$Variables$Mutation$MarkEpisodeWatched(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$MarkEpisodeWatched ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$episodeId = episodeId;
    final lOther$episodeId = other.episodeId;
    if (l$episodeId != lOther$episodeId) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$episodeId = episodeId;
    return Object.hashAll([l$episodeId]);
  }
}

abstract class CopyWith$Variables$Mutation$MarkEpisodeWatched<TRes> {
  factory CopyWith$Variables$Mutation$MarkEpisodeWatched(
    Variables$Mutation$MarkEpisodeWatched instance,
    TRes Function(Variables$Mutation$MarkEpisodeWatched) then,
  ) = _CopyWithImpl$Variables$Mutation$MarkEpisodeWatched;

  factory CopyWith$Variables$Mutation$MarkEpisodeWatched.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$MarkEpisodeWatched;

  TRes call({String? episodeId});
}

class _CopyWithImpl$Variables$Mutation$MarkEpisodeWatched<TRes>
    implements CopyWith$Variables$Mutation$MarkEpisodeWatched<TRes> {
  _CopyWithImpl$Variables$Mutation$MarkEpisodeWatched(
    this._instance,
    this._then,
  );

  final Variables$Mutation$MarkEpisodeWatched _instance;

  final TRes Function(Variables$Mutation$MarkEpisodeWatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? episodeId = _undefined}) => _then(
        Variables$Mutation$MarkEpisodeWatched._({
          ..._instance._$data,
          if (episodeId != _undefined && episodeId != null)
            'episodeId': (episodeId as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$MarkEpisodeWatched<TRes>
    implements CopyWith$Variables$Mutation$MarkEpisodeWatched<TRes> {
  _CopyWithStubImpl$Variables$Mutation$MarkEpisodeWatched(this._res);

  TRes _res;

  call({String? episodeId}) => _res;
}

class Mutation$MarkEpisodeWatched {
  Mutation$MarkEpisodeWatched({
    this.markEpisodeWatched,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$MarkEpisodeWatched.fromJson(Map<String, dynamic> json) {
    final l$markEpisodeWatched = json['markEpisodeWatched'];
    final l$$__typename = json['__typename'];
    return Mutation$MarkEpisodeWatched(
      markEpisodeWatched: l$markEpisodeWatched == null
          ? null
          : Mutation$MarkEpisodeWatched$markEpisodeWatched.fromJson(
              (l$markEpisodeWatched as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$MarkEpisodeWatched$markEpisodeWatched? markEpisodeWatched;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$markEpisodeWatched = markEpisodeWatched;
    _resultData['markEpisodeWatched'] = l$markEpisodeWatched?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$markEpisodeWatched = markEpisodeWatched;
    final l$$__typename = $__typename;
    return Object.hashAll([l$markEpisodeWatched, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$MarkEpisodeWatched ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$markEpisodeWatched = markEpisodeWatched;
    final lOther$markEpisodeWatched = other.markEpisodeWatched;
    if (l$markEpisodeWatched != lOther$markEpisodeWatched) {
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

extension UtilityExtension$Mutation$MarkEpisodeWatched
    on Mutation$MarkEpisodeWatched {
  CopyWith$Mutation$MarkEpisodeWatched<Mutation$MarkEpisodeWatched>
      get copyWith => CopyWith$Mutation$MarkEpisodeWatched(this, (i) => i);
}

abstract class CopyWith$Mutation$MarkEpisodeWatched<TRes> {
  factory CopyWith$Mutation$MarkEpisodeWatched(
    Mutation$MarkEpisodeWatched instance,
    TRes Function(Mutation$MarkEpisodeWatched) then,
  ) = _CopyWithImpl$Mutation$MarkEpisodeWatched;

  factory CopyWith$Mutation$MarkEpisodeWatched.stub(TRes res) =
      _CopyWithStubImpl$Mutation$MarkEpisodeWatched;

  TRes call({
    Mutation$MarkEpisodeWatched$markEpisodeWatched? markEpisodeWatched,
    String? $__typename,
  });
  CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched<TRes>
      get markEpisodeWatched;
}

class _CopyWithImpl$Mutation$MarkEpisodeWatched<TRes>
    implements CopyWith$Mutation$MarkEpisodeWatched<TRes> {
  _CopyWithImpl$Mutation$MarkEpisodeWatched(this._instance, this._then);

  final Mutation$MarkEpisodeWatched _instance;

  final TRes Function(Mutation$MarkEpisodeWatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? markEpisodeWatched = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$MarkEpisodeWatched(
          markEpisodeWatched: markEpisodeWatched == _undefined
              ? _instance.markEpisodeWatched
              : (markEpisodeWatched
                  as Mutation$MarkEpisodeWatched$markEpisodeWatched?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched<TRes>
      get markEpisodeWatched {
    final local$markEpisodeWatched = _instance.markEpisodeWatched;
    return local$markEpisodeWatched == null
        ? CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched.stub(
            _then(_instance),
          )
        : CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched(
            local$markEpisodeWatched,
            (e) => call(markEpisodeWatched: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$MarkEpisodeWatched<TRes>
    implements CopyWith$Mutation$MarkEpisodeWatched<TRes> {
  _CopyWithStubImpl$Mutation$MarkEpisodeWatched(this._res);

  TRes _res;

  call({
    Mutation$MarkEpisodeWatched$markEpisodeWatched? markEpisodeWatched,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched<TRes>
      get markEpisodeWatched =>
          CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched.stub(_res);
}

const documentNodeMutationMarkEpisodeWatched = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'MarkEpisodeWatched'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'episodeId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'markEpisodeWatched'),
            alias: null,
            arguments: [
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
                  name: NameNode(value: 'title'),
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

class Mutation$MarkEpisodeWatched$markEpisodeWatched {
  Mutation$MarkEpisodeWatched$markEpisodeWatched({
    required this.id,
    this.title,
    this.$__typename = 'Episode',
  });

  factory Mutation$MarkEpisodeWatched$markEpisodeWatched.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$title = json['title'];
    final l$$__typename = json['__typename'];
    return Mutation$MarkEpisodeWatched$markEpisodeWatched(
      id: (l$id as String),
      title: (l$title as String?),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String? title;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$title = title;
    final l$$__typename = $__typename;
    return Object.hashAll([l$id, l$title, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$MarkEpisodeWatched$markEpisodeWatched ||
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
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Mutation$MarkEpisodeWatched$markEpisodeWatched
    on Mutation$MarkEpisodeWatched$markEpisodeWatched {
  CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched<
          Mutation$MarkEpisodeWatched$markEpisodeWatched>
      get copyWith => CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched(
          this, (i) => i);
}

abstract class CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched<TRes> {
  factory CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched(
    Mutation$MarkEpisodeWatched$markEpisodeWatched instance,
    TRes Function(Mutation$MarkEpisodeWatched$markEpisodeWatched) then,
  ) = _CopyWithImpl$Mutation$MarkEpisodeWatched$markEpisodeWatched;

  factory CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched.stub(
    TRes res,
  ) = _CopyWithStubImpl$Mutation$MarkEpisodeWatched$markEpisodeWatched;

  TRes call({String? id, String? title, String? $__typename});
}

class _CopyWithImpl$Mutation$MarkEpisodeWatched$markEpisodeWatched<TRes>
    implements CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched<TRes> {
  _CopyWithImpl$Mutation$MarkEpisodeWatched$markEpisodeWatched(
    this._instance,
    this._then,
  );

  final Mutation$MarkEpisodeWatched$markEpisodeWatched _instance;

  final TRes Function(Mutation$MarkEpisodeWatched$markEpisodeWatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? title = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$MarkEpisodeWatched$markEpisodeWatched(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          title: title == _undefined ? _instance.title : (title as String?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$MarkEpisodeWatched$markEpisodeWatched<TRes>
    implements CopyWith$Mutation$MarkEpisodeWatched$markEpisodeWatched<TRes> {
  _CopyWithStubImpl$Mutation$MarkEpisodeWatched$markEpisodeWatched(this._res);

  TRes _res;

  call({String? id, String? title, String? $__typename}) => _res;
}

class Variables$Mutation$MarkEpisodeUnwatched {
  factory Variables$Mutation$MarkEpisodeUnwatched({
    required String episodeId,
  }) =>
      Variables$Mutation$MarkEpisodeUnwatched._({r'episodeId': episodeId});

  Variables$Mutation$MarkEpisodeUnwatched._(this._$data);

  factory Variables$Mutation$MarkEpisodeUnwatched.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$episodeId = data['episodeId'];
    result$data['episodeId'] = (l$episodeId as String);
    return Variables$Mutation$MarkEpisodeUnwatched._(result$data);
  }

  Map<String, dynamic> _$data;

  String get episodeId => (_$data['episodeId'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$episodeId = episodeId;
    result$data['episodeId'] = l$episodeId;
    return result$data;
  }

  CopyWith$Variables$Mutation$MarkEpisodeUnwatched<
          Variables$Mutation$MarkEpisodeUnwatched>
      get copyWith =>
          CopyWith$Variables$Mutation$MarkEpisodeUnwatched(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$MarkEpisodeUnwatched ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$episodeId = episodeId;
    final lOther$episodeId = other.episodeId;
    if (l$episodeId != lOther$episodeId) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$episodeId = episodeId;
    return Object.hashAll([l$episodeId]);
  }
}

abstract class CopyWith$Variables$Mutation$MarkEpisodeUnwatched<TRes> {
  factory CopyWith$Variables$Mutation$MarkEpisodeUnwatched(
    Variables$Mutation$MarkEpisodeUnwatched instance,
    TRes Function(Variables$Mutation$MarkEpisodeUnwatched) then,
  ) = _CopyWithImpl$Variables$Mutation$MarkEpisodeUnwatched;

  factory CopyWith$Variables$Mutation$MarkEpisodeUnwatched.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$MarkEpisodeUnwatched;

  TRes call({String? episodeId});
}

class _CopyWithImpl$Variables$Mutation$MarkEpisodeUnwatched<TRes>
    implements CopyWith$Variables$Mutation$MarkEpisodeUnwatched<TRes> {
  _CopyWithImpl$Variables$Mutation$MarkEpisodeUnwatched(
    this._instance,
    this._then,
  );

  final Variables$Mutation$MarkEpisodeUnwatched _instance;

  final TRes Function(Variables$Mutation$MarkEpisodeUnwatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? episodeId = _undefined}) => _then(
        Variables$Mutation$MarkEpisodeUnwatched._({
          ..._instance._$data,
          if (episodeId != _undefined && episodeId != null)
            'episodeId': (episodeId as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$MarkEpisodeUnwatched<TRes>
    implements CopyWith$Variables$Mutation$MarkEpisodeUnwatched<TRes> {
  _CopyWithStubImpl$Variables$Mutation$MarkEpisodeUnwatched(this._res);

  TRes _res;

  call({String? episodeId}) => _res;
}

class Mutation$MarkEpisodeUnwatched {
  Mutation$MarkEpisodeUnwatched({
    this.markEpisodeUnwatched,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$MarkEpisodeUnwatched.fromJson(Map<String, dynamic> json) {
    final l$markEpisodeUnwatched = json['markEpisodeUnwatched'];
    final l$$__typename = json['__typename'];
    return Mutation$MarkEpisodeUnwatched(
      markEpisodeUnwatched: l$markEpisodeUnwatched == null
          ? null
          : Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched.fromJson(
              (l$markEpisodeUnwatched as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched?
      markEpisodeUnwatched;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$markEpisodeUnwatched = markEpisodeUnwatched;
    _resultData['markEpisodeUnwatched'] = l$markEpisodeUnwatched?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$markEpisodeUnwatched = markEpisodeUnwatched;
    final l$$__typename = $__typename;
    return Object.hashAll([l$markEpisodeUnwatched, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$MarkEpisodeUnwatched ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$markEpisodeUnwatched = markEpisodeUnwatched;
    final lOther$markEpisodeUnwatched = other.markEpisodeUnwatched;
    if (l$markEpisodeUnwatched != lOther$markEpisodeUnwatched) {
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

extension UtilityExtension$Mutation$MarkEpisodeUnwatched
    on Mutation$MarkEpisodeUnwatched {
  CopyWith$Mutation$MarkEpisodeUnwatched<Mutation$MarkEpisodeUnwatched>
      get copyWith => CopyWith$Mutation$MarkEpisodeUnwatched(this, (i) => i);
}

abstract class CopyWith$Mutation$MarkEpisodeUnwatched<TRes> {
  factory CopyWith$Mutation$MarkEpisodeUnwatched(
    Mutation$MarkEpisodeUnwatched instance,
    TRes Function(Mutation$MarkEpisodeUnwatched) then,
  ) = _CopyWithImpl$Mutation$MarkEpisodeUnwatched;

  factory CopyWith$Mutation$MarkEpisodeUnwatched.stub(TRes res) =
      _CopyWithStubImpl$Mutation$MarkEpisodeUnwatched;

  TRes call({
    Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched? markEpisodeUnwatched,
    String? $__typename,
  });
  CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched<TRes>
      get markEpisodeUnwatched;
}

class _CopyWithImpl$Mutation$MarkEpisodeUnwatched<TRes>
    implements CopyWith$Mutation$MarkEpisodeUnwatched<TRes> {
  _CopyWithImpl$Mutation$MarkEpisodeUnwatched(this._instance, this._then);

  final Mutation$MarkEpisodeUnwatched _instance;

  final TRes Function(Mutation$MarkEpisodeUnwatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? markEpisodeUnwatched = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$MarkEpisodeUnwatched(
          markEpisodeUnwatched: markEpisodeUnwatched == _undefined
              ? _instance.markEpisodeUnwatched
              : (markEpisodeUnwatched
                  as Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched<TRes>
      get markEpisodeUnwatched {
    final local$markEpisodeUnwatched = _instance.markEpisodeUnwatched;
    return local$markEpisodeUnwatched == null
        ? CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched.stub(
            _then(_instance),
          )
        : CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched(
            local$markEpisodeUnwatched,
            (e) => call(markEpisodeUnwatched: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$MarkEpisodeUnwatched<TRes>
    implements CopyWith$Mutation$MarkEpisodeUnwatched<TRes> {
  _CopyWithStubImpl$Mutation$MarkEpisodeUnwatched(this._res);

  TRes _res;

  call({
    Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched? markEpisodeUnwatched,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched<TRes>
      get markEpisodeUnwatched =>
          CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched.stub(
              _res);
}

const documentNodeMutationMarkEpisodeUnwatched = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'MarkEpisodeUnwatched'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'episodeId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'markEpisodeUnwatched'),
            alias: null,
            arguments: [
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
                  name: NameNode(value: 'title'),
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

class Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched {
  Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched({
    required this.id,
    this.title,
    this.$__typename = 'Episode',
  });

  factory Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$title = json['title'];
    final l$$__typename = json['__typename'];
    return Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched(
      id: (l$id as String),
      title: (l$title as String?),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String? title;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$title = title;
    final l$$__typename = $__typename;
    return Object.hashAll([l$id, l$title, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched ||
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
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched
    on Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched {
  CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched<
          Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched>
      get copyWith =>
          CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched(
            this,
            (i) => i,
          );
}

abstract class CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched<
    TRes> {
  factory CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched(
    Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched instance,
    TRes Function(Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched) then,
  ) = _CopyWithImpl$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched;

  factory CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched.stub(
    TRes res,
  ) = _CopyWithStubImpl$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched;

  TRes call({String? id, String? title, String? $__typename});
}

class _CopyWithImpl$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched<TRes>
    implements
        CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched<TRes> {
  _CopyWithImpl$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched(
    this._instance,
    this._then,
  );

  final Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched _instance;

  final TRes Function(Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? title = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          title: title == _undefined ? _instance.title : (title as String?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched<TRes>
    implements
        CopyWith$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched<TRes> {
  _CopyWithStubImpl$Mutation$MarkEpisodeUnwatched$markEpisodeUnwatched(
    this._res,
  );

  TRes _res;

  call({String? id, String? title, String? $__typename}) => _res;
}

class Variables$Mutation$MarkSeasonWatched {
  factory Variables$Mutation$MarkSeasonWatched({
    required String showId,
    required int seasonNumber,
  }) =>
      Variables$Mutation$MarkSeasonWatched._({
        r'showId': showId,
        r'seasonNumber': seasonNumber,
      });

  Variables$Mutation$MarkSeasonWatched._(this._$data);

  factory Variables$Mutation$MarkSeasonWatched.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$showId = data['showId'];
    result$data['showId'] = (l$showId as String);
    final l$seasonNumber = data['seasonNumber'];
    result$data['seasonNumber'] = (l$seasonNumber as int);
    return Variables$Mutation$MarkSeasonWatched._(result$data);
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

  CopyWith$Variables$Mutation$MarkSeasonWatched<
          Variables$Mutation$MarkSeasonWatched>
      get copyWith =>
          CopyWith$Variables$Mutation$MarkSeasonWatched(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$MarkSeasonWatched ||
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

abstract class CopyWith$Variables$Mutation$MarkSeasonWatched<TRes> {
  factory CopyWith$Variables$Mutation$MarkSeasonWatched(
    Variables$Mutation$MarkSeasonWatched instance,
    TRes Function(Variables$Mutation$MarkSeasonWatched) then,
  ) = _CopyWithImpl$Variables$Mutation$MarkSeasonWatched;

  factory CopyWith$Variables$Mutation$MarkSeasonWatched.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$MarkSeasonWatched;

  TRes call({String? showId, int? seasonNumber});
}

class _CopyWithImpl$Variables$Mutation$MarkSeasonWatched<TRes>
    implements CopyWith$Variables$Mutation$MarkSeasonWatched<TRes> {
  _CopyWithImpl$Variables$Mutation$MarkSeasonWatched(
    this._instance,
    this._then,
  );

  final Variables$Mutation$MarkSeasonWatched _instance;

  final TRes Function(Variables$Mutation$MarkSeasonWatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? showId = _undefined, Object? seasonNumber = _undefined}) =>
      _then(
        Variables$Mutation$MarkSeasonWatched._({
          ..._instance._$data,
          if (showId != _undefined && showId != null)
            'showId': (showId as String),
          if (seasonNumber != _undefined && seasonNumber != null)
            'seasonNumber': (seasonNumber as int),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$MarkSeasonWatched<TRes>
    implements CopyWith$Variables$Mutation$MarkSeasonWatched<TRes> {
  _CopyWithStubImpl$Variables$Mutation$MarkSeasonWatched(this._res);

  TRes _res;

  call({String? showId, int? seasonNumber}) => _res;
}

class Mutation$MarkSeasonWatched {
  Mutation$MarkSeasonWatched({
    this.markSeasonWatched,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$MarkSeasonWatched.fromJson(Map<String, dynamic> json) {
    final l$markSeasonWatched = json['markSeasonWatched'];
    final l$$__typename = json['__typename'];
    return Mutation$MarkSeasonWatched(
      markSeasonWatched: l$markSeasonWatched == null
          ? null
          : Mutation$MarkSeasonWatched$markSeasonWatched.fromJson(
              (l$markSeasonWatched as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$MarkSeasonWatched$markSeasonWatched? markSeasonWatched;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$markSeasonWatched = markSeasonWatched;
    _resultData['markSeasonWatched'] = l$markSeasonWatched?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$markSeasonWatched = markSeasonWatched;
    final l$$__typename = $__typename;
    return Object.hashAll([l$markSeasonWatched, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$MarkSeasonWatched ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$markSeasonWatched = markSeasonWatched;
    final lOther$markSeasonWatched = other.markSeasonWatched;
    if (l$markSeasonWatched != lOther$markSeasonWatched) {
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

extension UtilityExtension$Mutation$MarkSeasonWatched
    on Mutation$MarkSeasonWatched {
  CopyWith$Mutation$MarkSeasonWatched<Mutation$MarkSeasonWatched>
      get copyWith => CopyWith$Mutation$MarkSeasonWatched(this, (i) => i);
}

abstract class CopyWith$Mutation$MarkSeasonWatched<TRes> {
  factory CopyWith$Mutation$MarkSeasonWatched(
    Mutation$MarkSeasonWatched instance,
    TRes Function(Mutation$MarkSeasonWatched) then,
  ) = _CopyWithImpl$Mutation$MarkSeasonWatched;

  factory CopyWith$Mutation$MarkSeasonWatched.stub(TRes res) =
      _CopyWithStubImpl$Mutation$MarkSeasonWatched;

  TRes call({
    Mutation$MarkSeasonWatched$markSeasonWatched? markSeasonWatched,
    String? $__typename,
  });
  CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched<TRes>
      get markSeasonWatched;
}

class _CopyWithImpl$Mutation$MarkSeasonWatched<TRes>
    implements CopyWith$Mutation$MarkSeasonWatched<TRes> {
  _CopyWithImpl$Mutation$MarkSeasonWatched(this._instance, this._then);

  final Mutation$MarkSeasonWatched _instance;

  final TRes Function(Mutation$MarkSeasonWatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? markSeasonWatched = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$MarkSeasonWatched(
          markSeasonWatched: markSeasonWatched == _undefined
              ? _instance.markSeasonWatched
              : (markSeasonWatched
                  as Mutation$MarkSeasonWatched$markSeasonWatched?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched<TRes>
      get markSeasonWatched {
    final local$markSeasonWatched = _instance.markSeasonWatched;
    return local$markSeasonWatched == null
        ? CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched.stub(
            _then(_instance),
          )
        : CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched(
            local$markSeasonWatched,
            (e) => call(markSeasonWatched: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$MarkSeasonWatched<TRes>
    implements CopyWith$Mutation$MarkSeasonWatched<TRes> {
  _CopyWithStubImpl$Mutation$MarkSeasonWatched(this._res);

  TRes _res;

  call({
    Mutation$MarkSeasonWatched$markSeasonWatched? markSeasonWatched,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched<TRes>
      get markSeasonWatched =>
          CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched.stub(_res);
}

const documentNodeMutationMarkSeasonWatched = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'MarkSeasonWatched'),
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
            name: NameNode(value: 'markSeasonWatched'),
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
                  name: NameNode(value: 'title'),
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

class Mutation$MarkSeasonWatched$markSeasonWatched {
  Mutation$MarkSeasonWatched$markSeasonWatched({
    required this.id,
    required this.title,
    this.$__typename = 'TvShow',
  });

  factory Mutation$MarkSeasonWatched$markSeasonWatched.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$title = json['title'];
    final l$$__typename = json['__typename'];
    return Mutation$MarkSeasonWatched$markSeasonWatched(
      id: (l$id as String),
      title: (l$title as String),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String title;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$title = title;
    final l$$__typename = $__typename;
    return Object.hashAll([l$id, l$title, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$MarkSeasonWatched$markSeasonWatched ||
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
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Mutation$MarkSeasonWatched$markSeasonWatched
    on Mutation$MarkSeasonWatched$markSeasonWatched {
  CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched<
          Mutation$MarkSeasonWatched$markSeasonWatched>
      get copyWith =>
          CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched(this, (i) => i);
}

abstract class CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched<TRes> {
  factory CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched(
    Mutation$MarkSeasonWatched$markSeasonWatched instance,
    TRes Function(Mutation$MarkSeasonWatched$markSeasonWatched) then,
  ) = _CopyWithImpl$Mutation$MarkSeasonWatched$markSeasonWatched;

  factory CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched.stub(TRes res) =
      _CopyWithStubImpl$Mutation$MarkSeasonWatched$markSeasonWatched;

  TRes call({String? id, String? title, String? $__typename});
}

class _CopyWithImpl$Mutation$MarkSeasonWatched$markSeasonWatched<TRes>
    implements CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched<TRes> {
  _CopyWithImpl$Mutation$MarkSeasonWatched$markSeasonWatched(
    this._instance,
    this._then,
  );

  final Mutation$MarkSeasonWatched$markSeasonWatched _instance;

  final TRes Function(Mutation$MarkSeasonWatched$markSeasonWatched) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? title = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$MarkSeasonWatched$markSeasonWatched(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          title: title == _undefined || title == null
              ? _instance.title
              : (title as String),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$MarkSeasonWatched$markSeasonWatched<TRes>
    implements CopyWith$Mutation$MarkSeasonWatched$markSeasonWatched<TRes> {
  _CopyWithStubImpl$Mutation$MarkSeasonWatched$markSeasonWatched(this._res);

  TRes _res;

  call({String? id, String? title, String? $__typename}) => _res;
}
