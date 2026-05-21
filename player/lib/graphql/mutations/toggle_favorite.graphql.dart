import 'package:gql/ast.dart';

class Variables$Mutation$ToggleFavorite {
  factory Variables$Mutation$ToggleFavorite({required String mediaItemId}) =>
      Variables$Mutation$ToggleFavorite._({r'mediaItemId': mediaItemId});

  Variables$Mutation$ToggleFavorite._(this._$data);

  factory Variables$Mutation$ToggleFavorite.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$mediaItemId = data['mediaItemId'];
    result$data['mediaItemId'] = (l$mediaItemId as String);
    return Variables$Mutation$ToggleFavorite._(result$data);
  }

  Map<String, dynamic> _$data;

  String get mediaItemId => (_$data['mediaItemId'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$mediaItemId = mediaItemId;
    result$data['mediaItemId'] = l$mediaItemId;
    return result$data;
  }

  CopyWith$Variables$Mutation$ToggleFavorite<Variables$Mutation$ToggleFavorite>
      get copyWith =>
          CopyWith$Variables$Mutation$ToggleFavorite(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$ToggleFavorite ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$mediaItemId = mediaItemId;
    final lOther$mediaItemId = other.mediaItemId;
    if (l$mediaItemId != lOther$mediaItemId) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$mediaItemId = mediaItemId;
    return Object.hashAll([l$mediaItemId]);
  }
}

abstract class CopyWith$Variables$Mutation$ToggleFavorite<TRes> {
  factory CopyWith$Variables$Mutation$ToggleFavorite(
    Variables$Mutation$ToggleFavorite instance,
    TRes Function(Variables$Mutation$ToggleFavorite) then,
  ) = _CopyWithImpl$Variables$Mutation$ToggleFavorite;

  factory CopyWith$Variables$Mutation$ToggleFavorite.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$ToggleFavorite;

  TRes call({String? mediaItemId});
}

class _CopyWithImpl$Variables$Mutation$ToggleFavorite<TRes>
    implements CopyWith$Variables$Mutation$ToggleFavorite<TRes> {
  _CopyWithImpl$Variables$Mutation$ToggleFavorite(this._instance, this._then);

  final Variables$Mutation$ToggleFavorite _instance;

  final TRes Function(Variables$Mutation$ToggleFavorite) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? mediaItemId = _undefined}) => _then(
        Variables$Mutation$ToggleFavorite._({
          ..._instance._$data,
          if (mediaItemId != _undefined && mediaItemId != null)
            'mediaItemId': (mediaItemId as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$ToggleFavorite<TRes>
    implements CopyWith$Variables$Mutation$ToggleFavorite<TRes> {
  _CopyWithStubImpl$Variables$Mutation$ToggleFavorite(this._res);

  TRes _res;

  call({String? mediaItemId}) => _res;
}

class Mutation$ToggleFavorite {
  Mutation$ToggleFavorite({
    this.toggleFavorite,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$ToggleFavorite.fromJson(Map<String, dynamic> json) {
    final l$toggleFavorite = json['toggleFavorite'];
    final l$$__typename = json['__typename'];
    return Mutation$ToggleFavorite(
      toggleFavorite: l$toggleFavorite == null
          ? null
          : Mutation$ToggleFavorite$toggleFavorite.fromJson(
              (l$toggleFavorite as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$ToggleFavorite$toggleFavorite? toggleFavorite;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$toggleFavorite = toggleFavorite;
    _resultData['toggleFavorite'] = l$toggleFavorite?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$toggleFavorite = toggleFavorite;
    final l$$__typename = $__typename;
    return Object.hashAll([l$toggleFavorite, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$ToggleFavorite || runtimeType != other.runtimeType) {
      return false;
    }
    final l$toggleFavorite = toggleFavorite;
    final lOther$toggleFavorite = other.toggleFavorite;
    if (l$toggleFavorite != lOther$toggleFavorite) {
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

extension UtilityExtension$Mutation$ToggleFavorite on Mutation$ToggleFavorite {
  CopyWith$Mutation$ToggleFavorite<Mutation$ToggleFavorite> get copyWith =>
      CopyWith$Mutation$ToggleFavorite(this, (i) => i);
}

abstract class CopyWith$Mutation$ToggleFavorite<TRes> {
  factory CopyWith$Mutation$ToggleFavorite(
    Mutation$ToggleFavorite instance,
    TRes Function(Mutation$ToggleFavorite) then,
  ) = _CopyWithImpl$Mutation$ToggleFavorite;

  factory CopyWith$Mutation$ToggleFavorite.stub(TRes res) =
      _CopyWithStubImpl$Mutation$ToggleFavorite;

  TRes call({
    Mutation$ToggleFavorite$toggleFavorite? toggleFavorite,
    String? $__typename,
  });
  CopyWith$Mutation$ToggleFavorite$toggleFavorite<TRes> get toggleFavorite;
}

class _CopyWithImpl$Mutation$ToggleFavorite<TRes>
    implements CopyWith$Mutation$ToggleFavorite<TRes> {
  _CopyWithImpl$Mutation$ToggleFavorite(this._instance, this._then);

  final Mutation$ToggleFavorite _instance;

  final TRes Function(Mutation$ToggleFavorite) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? toggleFavorite = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$ToggleFavorite(
          toggleFavorite: toggleFavorite == _undefined
              ? _instance.toggleFavorite
              : (toggleFavorite as Mutation$ToggleFavorite$toggleFavorite?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$ToggleFavorite$toggleFavorite<TRes> get toggleFavorite {
    final local$toggleFavorite = _instance.toggleFavorite;
    return local$toggleFavorite == null
        ? CopyWith$Mutation$ToggleFavorite$toggleFavorite.stub(_then(_instance))
        : CopyWith$Mutation$ToggleFavorite$toggleFavorite(
            local$toggleFavorite,
            (e) => call(toggleFavorite: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$ToggleFavorite<TRes>
    implements CopyWith$Mutation$ToggleFavorite<TRes> {
  _CopyWithStubImpl$Mutation$ToggleFavorite(this._res);

  TRes _res;

  call({
    Mutation$ToggleFavorite$toggleFavorite? toggleFavorite,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$ToggleFavorite$toggleFavorite<TRes> get toggleFavorite =>
      CopyWith$Mutation$ToggleFavorite$toggleFavorite.stub(_res);
}

const documentNodeMutationToggleFavorite = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'ToggleFavorite'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'mediaItemId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'toggleFavorite'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'mediaItemId'),
                value: VariableNode(name: NameNode(value: 'mediaItemId')),
              ),
            ],
            directives: [],
            selectionSet: SelectionSetNode(
              selections: [
                FieldNode(
                  name: NameNode(value: 'isFavorite'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'mediaItemId'),
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

class Mutation$ToggleFavorite$toggleFavorite {
  Mutation$ToggleFavorite$toggleFavorite({
    required this.isFavorite,
    required this.mediaItemId,
    this.$__typename = 'ToggleFavoriteResult',
  });

  factory Mutation$ToggleFavorite$toggleFavorite.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$isFavorite = json['isFavorite'];
    final l$mediaItemId = json['mediaItemId'];
    final l$$__typename = json['__typename'];
    return Mutation$ToggleFavorite$toggleFavorite(
      isFavorite: (l$isFavorite as bool),
      mediaItemId: (l$mediaItemId as String),
      $__typename: (l$$__typename as String),
    );
  }

  final bool isFavorite;

  final String mediaItemId;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$isFavorite = isFavorite;
    _resultData['isFavorite'] = l$isFavorite;
    final l$mediaItemId = mediaItemId;
    _resultData['mediaItemId'] = l$mediaItemId;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$isFavorite = isFavorite;
    final l$mediaItemId = mediaItemId;
    final l$$__typename = $__typename;
    return Object.hashAll([l$isFavorite, l$mediaItemId, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$ToggleFavorite$toggleFavorite ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$isFavorite = isFavorite;
    final lOther$isFavorite = other.isFavorite;
    if (l$isFavorite != lOther$isFavorite) {
      return false;
    }
    final l$mediaItemId = mediaItemId;
    final lOther$mediaItemId = other.mediaItemId;
    if (l$mediaItemId != lOther$mediaItemId) {
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

extension UtilityExtension$Mutation$ToggleFavorite$toggleFavorite
    on Mutation$ToggleFavorite$toggleFavorite {
  CopyWith$Mutation$ToggleFavorite$toggleFavorite<
          Mutation$ToggleFavorite$toggleFavorite>
      get copyWith =>
          CopyWith$Mutation$ToggleFavorite$toggleFavorite(this, (i) => i);
}

abstract class CopyWith$Mutation$ToggleFavorite$toggleFavorite<TRes> {
  factory CopyWith$Mutation$ToggleFavorite$toggleFavorite(
    Mutation$ToggleFavorite$toggleFavorite instance,
    TRes Function(Mutation$ToggleFavorite$toggleFavorite) then,
  ) = _CopyWithImpl$Mutation$ToggleFavorite$toggleFavorite;

  factory CopyWith$Mutation$ToggleFavorite$toggleFavorite.stub(TRes res) =
      _CopyWithStubImpl$Mutation$ToggleFavorite$toggleFavorite;

  TRes call({bool? isFavorite, String? mediaItemId, String? $__typename});
}

class _CopyWithImpl$Mutation$ToggleFavorite$toggleFavorite<TRes>
    implements CopyWith$Mutation$ToggleFavorite$toggleFavorite<TRes> {
  _CopyWithImpl$Mutation$ToggleFavorite$toggleFavorite(
    this._instance,
    this._then,
  );

  final Mutation$ToggleFavorite$toggleFavorite _instance;

  final TRes Function(Mutation$ToggleFavorite$toggleFavorite) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? isFavorite = _undefined,
    Object? mediaItemId = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$ToggleFavorite$toggleFavorite(
          isFavorite: isFavorite == _undefined || isFavorite == null
              ? _instance.isFavorite
              : (isFavorite as bool),
          mediaItemId: mediaItemId == _undefined || mediaItemId == null
              ? _instance.mediaItemId
              : (mediaItemId as String),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$ToggleFavorite$toggleFavorite<TRes>
    implements CopyWith$Mutation$ToggleFavorite$toggleFavorite<TRes> {
  _CopyWithStubImpl$Mutation$ToggleFavorite$toggleFavorite(this._res);

  TRes _res;

  call({bool? isFavorite, String? mediaItemId, String? $__typename}) => _res;
}
