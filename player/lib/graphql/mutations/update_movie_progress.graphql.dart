import '../fragments/progress_fragment.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Mutation$UpdateMovieProgress {
  factory Variables$Mutation$UpdateMovieProgress({
    required String movieId,
    required int positionSeconds,
    int? durationSeconds,
  }) =>
      Variables$Mutation$UpdateMovieProgress._({
        r'movieId': movieId,
        r'positionSeconds': positionSeconds,
        if (durationSeconds != null) r'durationSeconds': durationSeconds,
      });

  Variables$Mutation$UpdateMovieProgress._(this._$data);

  factory Variables$Mutation$UpdateMovieProgress.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$movieId = data['movieId'];
    result$data['movieId'] = (l$movieId as String);
    final l$positionSeconds = data['positionSeconds'];
    result$data['positionSeconds'] = (l$positionSeconds as int);
    if (data.containsKey('durationSeconds')) {
      final l$durationSeconds = data['durationSeconds'];
      result$data['durationSeconds'] = (l$durationSeconds as int?);
    }
    return Variables$Mutation$UpdateMovieProgress._(result$data);
  }

  Map<String, dynamic> _$data;

  String get movieId => (_$data['movieId'] as String);

  int get positionSeconds => (_$data['positionSeconds'] as int);

  int? get durationSeconds => (_$data['durationSeconds'] as int?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$movieId = movieId;
    result$data['movieId'] = l$movieId;
    final l$positionSeconds = positionSeconds;
    result$data['positionSeconds'] = l$positionSeconds;
    if (_$data.containsKey('durationSeconds')) {
      final l$durationSeconds = durationSeconds;
      result$data['durationSeconds'] = l$durationSeconds;
    }
    return result$data;
  }

  CopyWith$Variables$Mutation$UpdateMovieProgress<
          Variables$Mutation$UpdateMovieProgress>
      get copyWith =>
          CopyWith$Variables$Mutation$UpdateMovieProgress(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$UpdateMovieProgress ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$movieId = movieId;
    final lOther$movieId = other.movieId;
    if (l$movieId != lOther$movieId) {
      return false;
    }
    final l$positionSeconds = positionSeconds;
    final lOther$positionSeconds = other.positionSeconds;
    if (l$positionSeconds != lOther$positionSeconds) {
      return false;
    }
    final l$durationSeconds = durationSeconds;
    final lOther$durationSeconds = other.durationSeconds;
    if (_$data.containsKey('durationSeconds') !=
        other._$data.containsKey('durationSeconds')) {
      return false;
    }
    if (l$durationSeconds != lOther$durationSeconds) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$movieId = movieId;
    final l$positionSeconds = positionSeconds;
    final l$durationSeconds = durationSeconds;
    return Object.hashAll([
      l$movieId,
      l$positionSeconds,
      _$data.containsKey('durationSeconds') ? l$durationSeconds : const {},
    ]);
  }
}

abstract class CopyWith$Variables$Mutation$UpdateMovieProgress<TRes> {
  factory CopyWith$Variables$Mutation$UpdateMovieProgress(
    Variables$Mutation$UpdateMovieProgress instance,
    TRes Function(Variables$Mutation$UpdateMovieProgress) then,
  ) = _CopyWithImpl$Variables$Mutation$UpdateMovieProgress;

  factory CopyWith$Variables$Mutation$UpdateMovieProgress.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$UpdateMovieProgress;

  TRes call({String? movieId, int? positionSeconds, int? durationSeconds});
}

class _CopyWithImpl$Variables$Mutation$UpdateMovieProgress<TRes>
    implements CopyWith$Variables$Mutation$UpdateMovieProgress<TRes> {
  _CopyWithImpl$Variables$Mutation$UpdateMovieProgress(
    this._instance,
    this._then,
  );

  final Variables$Mutation$UpdateMovieProgress _instance;

  final TRes Function(Variables$Mutation$UpdateMovieProgress) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? movieId = _undefined,
    Object? positionSeconds = _undefined,
    Object? durationSeconds = _undefined,
  }) =>
      _then(
        Variables$Mutation$UpdateMovieProgress._({
          ..._instance._$data,
          if (movieId != _undefined && movieId != null)
            'movieId': (movieId as String),
          if (positionSeconds != _undefined && positionSeconds != null)
            'positionSeconds': (positionSeconds as int),
          if (durationSeconds != _undefined)
            'durationSeconds': (durationSeconds as int?),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$UpdateMovieProgress<TRes>
    implements CopyWith$Variables$Mutation$UpdateMovieProgress<TRes> {
  _CopyWithStubImpl$Variables$Mutation$UpdateMovieProgress(this._res);

  TRes _res;

  call({String? movieId, int? positionSeconds, int? durationSeconds}) => _res;
}

class Mutation$UpdateMovieProgress {
  Mutation$UpdateMovieProgress({
    this.updateMovieProgress,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$UpdateMovieProgress.fromJson(Map<String, dynamic> json) {
    final l$updateMovieProgress = json['updateMovieProgress'];
    final l$$__typename = json['__typename'];
    return Mutation$UpdateMovieProgress(
      updateMovieProgress: l$updateMovieProgress == null
          ? null
          : Fragment$ProgressFragment.fromJson(
              (l$updateMovieProgress as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Fragment$ProgressFragment? updateMovieProgress;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$updateMovieProgress = updateMovieProgress;
    _resultData['updateMovieProgress'] = l$updateMovieProgress?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$updateMovieProgress = updateMovieProgress;
    final l$$__typename = $__typename;
    return Object.hashAll([l$updateMovieProgress, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$UpdateMovieProgress ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$updateMovieProgress = updateMovieProgress;
    final lOther$updateMovieProgress = other.updateMovieProgress;
    if (l$updateMovieProgress != lOther$updateMovieProgress) {
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

extension UtilityExtension$Mutation$UpdateMovieProgress
    on Mutation$UpdateMovieProgress {
  CopyWith$Mutation$UpdateMovieProgress<Mutation$UpdateMovieProgress>
      get copyWith => CopyWith$Mutation$UpdateMovieProgress(this, (i) => i);
}

abstract class CopyWith$Mutation$UpdateMovieProgress<TRes> {
  factory CopyWith$Mutation$UpdateMovieProgress(
    Mutation$UpdateMovieProgress instance,
    TRes Function(Mutation$UpdateMovieProgress) then,
  ) = _CopyWithImpl$Mutation$UpdateMovieProgress;

  factory CopyWith$Mutation$UpdateMovieProgress.stub(TRes res) =
      _CopyWithStubImpl$Mutation$UpdateMovieProgress;

  TRes call({
    Fragment$ProgressFragment? updateMovieProgress,
    String? $__typename,
  });
  CopyWith$Fragment$ProgressFragment<TRes> get updateMovieProgress;
}

class _CopyWithImpl$Mutation$UpdateMovieProgress<TRes>
    implements CopyWith$Mutation$UpdateMovieProgress<TRes> {
  _CopyWithImpl$Mutation$UpdateMovieProgress(this._instance, this._then);

  final Mutation$UpdateMovieProgress _instance;

  final TRes Function(Mutation$UpdateMovieProgress) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? updateMovieProgress = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$UpdateMovieProgress(
          updateMovieProgress: updateMovieProgress == _undefined
              ? _instance.updateMovieProgress
              : (updateMovieProgress as Fragment$ProgressFragment?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Fragment$ProgressFragment<TRes> get updateMovieProgress {
    final local$updateMovieProgress = _instance.updateMovieProgress;
    return local$updateMovieProgress == null
        ? CopyWith$Fragment$ProgressFragment.stub(_then(_instance))
        : CopyWith$Fragment$ProgressFragment(
            local$updateMovieProgress,
            (e) => call(updateMovieProgress: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$UpdateMovieProgress<TRes>
    implements CopyWith$Mutation$UpdateMovieProgress<TRes> {
  _CopyWithStubImpl$Mutation$UpdateMovieProgress(this._res);

  TRes _res;

  call({Fragment$ProgressFragment? updateMovieProgress, String? $__typename}) =>
      _res;

  CopyWith$Fragment$ProgressFragment<TRes> get updateMovieProgress =>
      CopyWith$Fragment$ProgressFragment.stub(_res);
}

const documentNodeMutationUpdateMovieProgress = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'UpdateMovieProgress'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'movieId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'positionSeconds')),
          type: NamedTypeNode(name: NameNode(value: 'Int'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'durationSeconds')),
          type: NamedTypeNode(name: NameNode(value: 'Int'), isNonNull: false),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'updateMovieProgress'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'movieId'),
                value: VariableNode(name: NameNode(value: 'movieId')),
              ),
              ArgumentNode(
                name: NameNode(value: 'positionSeconds'),
                value: VariableNode(name: NameNode(value: 'positionSeconds')),
              ),
              ArgumentNode(
                name: NameNode(value: 'durationSeconds'),
                value: VariableNode(name: NameNode(value: 'durationSeconds')),
              ),
            ],
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
  ],
);
