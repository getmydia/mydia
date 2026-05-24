import '../fragments/progress_fragment.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Mutation$UpdateEpisodeProgress {
  factory Variables$Mutation$UpdateEpisodeProgress({
    required String episodeId,
    required int positionSeconds,
    int? durationSeconds,
  }) =>
      Variables$Mutation$UpdateEpisodeProgress._({
        r'episodeId': episodeId,
        r'positionSeconds': positionSeconds,
        if (durationSeconds != null) r'durationSeconds': durationSeconds,
      });

  Variables$Mutation$UpdateEpisodeProgress._(this._$data);

  factory Variables$Mutation$UpdateEpisodeProgress.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$episodeId = data['episodeId'];
    result$data['episodeId'] = (l$episodeId as String);
    final l$positionSeconds = data['positionSeconds'];
    result$data['positionSeconds'] = (l$positionSeconds as int);
    if (data.containsKey('durationSeconds')) {
      final l$durationSeconds = data['durationSeconds'];
      result$data['durationSeconds'] = (l$durationSeconds as int?);
    }
    return Variables$Mutation$UpdateEpisodeProgress._(result$data);
  }

  Map<String, dynamic> _$data;

  String get episodeId => (_$data['episodeId'] as String);

  int get positionSeconds => (_$data['positionSeconds'] as int);

  int? get durationSeconds => (_$data['durationSeconds'] as int?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$episodeId = episodeId;
    result$data['episodeId'] = l$episodeId;
    final l$positionSeconds = positionSeconds;
    result$data['positionSeconds'] = l$positionSeconds;
    if (_$data.containsKey('durationSeconds')) {
      final l$durationSeconds = durationSeconds;
      result$data['durationSeconds'] = l$durationSeconds;
    }
    return result$data;
  }

  CopyWith$Variables$Mutation$UpdateEpisodeProgress<
          Variables$Mutation$UpdateEpisodeProgress>
      get copyWith =>
          CopyWith$Variables$Mutation$UpdateEpisodeProgress(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$UpdateEpisodeProgress ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$episodeId = episodeId;
    final lOther$episodeId = other.episodeId;
    if (l$episodeId != lOther$episodeId) {
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
    final l$episodeId = episodeId;
    final l$positionSeconds = positionSeconds;
    final l$durationSeconds = durationSeconds;
    return Object.hashAll([
      l$episodeId,
      l$positionSeconds,
      _$data.containsKey('durationSeconds') ? l$durationSeconds : const {},
    ]);
  }
}

abstract class CopyWith$Variables$Mutation$UpdateEpisodeProgress<TRes> {
  factory CopyWith$Variables$Mutation$UpdateEpisodeProgress(
    Variables$Mutation$UpdateEpisodeProgress instance,
    TRes Function(Variables$Mutation$UpdateEpisodeProgress) then,
  ) = _CopyWithImpl$Variables$Mutation$UpdateEpisodeProgress;

  factory CopyWith$Variables$Mutation$UpdateEpisodeProgress.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$UpdateEpisodeProgress;

  TRes call({String? episodeId, int? positionSeconds, int? durationSeconds});
}

class _CopyWithImpl$Variables$Mutation$UpdateEpisodeProgress<TRes>
    implements CopyWith$Variables$Mutation$UpdateEpisodeProgress<TRes> {
  _CopyWithImpl$Variables$Mutation$UpdateEpisodeProgress(
    this._instance,
    this._then,
  );

  final Variables$Mutation$UpdateEpisodeProgress _instance;

  final TRes Function(Variables$Mutation$UpdateEpisodeProgress) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? episodeId = _undefined,
    Object? positionSeconds = _undefined,
    Object? durationSeconds = _undefined,
  }) =>
      _then(
        Variables$Mutation$UpdateEpisodeProgress._({
          ..._instance._$data,
          if (episodeId != _undefined && episodeId != null)
            'episodeId': (episodeId as String),
          if (positionSeconds != _undefined && positionSeconds != null)
            'positionSeconds': (positionSeconds as int),
          if (durationSeconds != _undefined)
            'durationSeconds': (durationSeconds as int?),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$UpdateEpisodeProgress<TRes>
    implements CopyWith$Variables$Mutation$UpdateEpisodeProgress<TRes> {
  _CopyWithStubImpl$Variables$Mutation$UpdateEpisodeProgress(this._res);

  TRes _res;

  call({String? episodeId, int? positionSeconds, int? durationSeconds}) => _res;
}

class Mutation$UpdateEpisodeProgress {
  Mutation$UpdateEpisodeProgress({
    this.updateEpisodeProgress,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$UpdateEpisodeProgress.fromJson(Map<String, dynamic> json) {
    final l$updateEpisodeProgress = json['updateEpisodeProgress'];
    final l$$__typename = json['__typename'];
    return Mutation$UpdateEpisodeProgress(
      updateEpisodeProgress: l$updateEpisodeProgress == null
          ? null
          : Fragment$ProgressFragment.fromJson(
              (l$updateEpisodeProgress as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Fragment$ProgressFragment? updateEpisodeProgress;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$updateEpisodeProgress = updateEpisodeProgress;
    _resultData['updateEpisodeProgress'] = l$updateEpisodeProgress?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$updateEpisodeProgress = updateEpisodeProgress;
    final l$$__typename = $__typename;
    return Object.hashAll([l$updateEpisodeProgress, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$UpdateEpisodeProgress ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$updateEpisodeProgress = updateEpisodeProgress;
    final lOther$updateEpisodeProgress = other.updateEpisodeProgress;
    if (l$updateEpisodeProgress != lOther$updateEpisodeProgress) {
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

extension UtilityExtension$Mutation$UpdateEpisodeProgress
    on Mutation$UpdateEpisodeProgress {
  CopyWith$Mutation$UpdateEpisodeProgress<Mutation$UpdateEpisodeProgress>
      get copyWith => CopyWith$Mutation$UpdateEpisodeProgress(this, (i) => i);
}

abstract class CopyWith$Mutation$UpdateEpisodeProgress<TRes> {
  factory CopyWith$Mutation$UpdateEpisodeProgress(
    Mutation$UpdateEpisodeProgress instance,
    TRes Function(Mutation$UpdateEpisodeProgress) then,
  ) = _CopyWithImpl$Mutation$UpdateEpisodeProgress;

  factory CopyWith$Mutation$UpdateEpisodeProgress.stub(TRes res) =
      _CopyWithStubImpl$Mutation$UpdateEpisodeProgress;

  TRes call({
    Fragment$ProgressFragment? updateEpisodeProgress,
    String? $__typename,
  });
  CopyWith$Fragment$ProgressFragment<TRes> get updateEpisodeProgress;
}

class _CopyWithImpl$Mutation$UpdateEpisodeProgress<TRes>
    implements CopyWith$Mutation$UpdateEpisodeProgress<TRes> {
  _CopyWithImpl$Mutation$UpdateEpisodeProgress(this._instance, this._then);

  final Mutation$UpdateEpisodeProgress _instance;

  final TRes Function(Mutation$UpdateEpisodeProgress) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? updateEpisodeProgress = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$UpdateEpisodeProgress(
          updateEpisodeProgress: updateEpisodeProgress == _undefined
              ? _instance.updateEpisodeProgress
              : (updateEpisodeProgress as Fragment$ProgressFragment?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Fragment$ProgressFragment<TRes> get updateEpisodeProgress {
    final local$updateEpisodeProgress = _instance.updateEpisodeProgress;
    return local$updateEpisodeProgress == null
        ? CopyWith$Fragment$ProgressFragment.stub(_then(_instance))
        : CopyWith$Fragment$ProgressFragment(
            local$updateEpisodeProgress,
            (e) => call(updateEpisodeProgress: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$UpdateEpisodeProgress<TRes>
    implements CopyWith$Mutation$UpdateEpisodeProgress<TRes> {
  _CopyWithStubImpl$Mutation$UpdateEpisodeProgress(this._res);

  TRes _res;

  call({
    Fragment$ProgressFragment? updateEpisodeProgress,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ProgressFragment<TRes> get updateEpisodeProgress =>
      CopyWith$Fragment$ProgressFragment.stub(_res);
}

const documentNodeMutationUpdateEpisodeProgress = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'UpdateEpisodeProgress'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'episodeId')),
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
            name: NameNode(value: 'updateEpisodeProgress'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'episodeId'),
                value: VariableNode(name: NameNode(value: 'episodeId')),
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
