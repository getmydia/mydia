import '../fragments/progress_fragment.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Subscription$ProgressUpdated {
  factory Variables$Subscription$ProgressUpdated({required String nodeId}) =>
      Variables$Subscription$ProgressUpdated._({r'nodeId': nodeId});

  Variables$Subscription$ProgressUpdated._(this._$data);

  factory Variables$Subscription$ProgressUpdated.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$nodeId = data['nodeId'];
    result$data['nodeId'] = (l$nodeId as String);
    return Variables$Subscription$ProgressUpdated._(result$data);
  }

  Map<String, dynamic> _$data;

  String get nodeId => (_$data['nodeId'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$nodeId = nodeId;
    result$data['nodeId'] = l$nodeId;
    return result$data;
  }

  CopyWith$Variables$Subscription$ProgressUpdated<
          Variables$Subscription$ProgressUpdated>
      get copyWith =>
          CopyWith$Variables$Subscription$ProgressUpdated(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Subscription$ProgressUpdated ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$nodeId = nodeId;
    final lOther$nodeId = other.nodeId;
    if (l$nodeId != lOther$nodeId) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$nodeId = nodeId;
    return Object.hashAll([l$nodeId]);
  }
}

abstract class CopyWith$Variables$Subscription$ProgressUpdated<TRes> {
  factory CopyWith$Variables$Subscription$ProgressUpdated(
    Variables$Subscription$ProgressUpdated instance,
    TRes Function(Variables$Subscription$ProgressUpdated) then,
  ) = _CopyWithImpl$Variables$Subscription$ProgressUpdated;

  factory CopyWith$Variables$Subscription$ProgressUpdated.stub(TRes res) =
      _CopyWithStubImpl$Variables$Subscription$ProgressUpdated;

  TRes call({String? nodeId});
}

class _CopyWithImpl$Variables$Subscription$ProgressUpdated<TRes>
    implements CopyWith$Variables$Subscription$ProgressUpdated<TRes> {
  _CopyWithImpl$Variables$Subscription$ProgressUpdated(
    this._instance,
    this._then,
  );

  final Variables$Subscription$ProgressUpdated _instance;

  final TRes Function(Variables$Subscription$ProgressUpdated) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? nodeId = _undefined}) => _then(
        Variables$Subscription$ProgressUpdated._({
          ..._instance._$data,
          if (nodeId != _undefined && nodeId != null)
            'nodeId': (nodeId as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Subscription$ProgressUpdated<TRes>
    implements CopyWith$Variables$Subscription$ProgressUpdated<TRes> {
  _CopyWithStubImpl$Variables$Subscription$ProgressUpdated(this._res);

  TRes _res;

  call({String? nodeId}) => _res;
}

class Subscription$ProgressUpdated {
  Subscription$ProgressUpdated({
    this.progressUpdated,
    this.$__typename = 'RootSubscriptionType',
  });

  factory Subscription$ProgressUpdated.fromJson(Map<String, dynamic> json) {
    final l$progressUpdated = json['progressUpdated'];
    final l$$__typename = json['__typename'];
    return Subscription$ProgressUpdated(
      progressUpdated: l$progressUpdated == null
          ? null
          : Fragment$ProgressFragment.fromJson(
              (l$progressUpdated as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Fragment$ProgressFragment? progressUpdated;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$progressUpdated = progressUpdated;
    _resultData['progressUpdated'] = l$progressUpdated?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$progressUpdated = progressUpdated;
    final l$$__typename = $__typename;
    return Object.hashAll([l$progressUpdated, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Subscription$ProgressUpdated ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$progressUpdated = progressUpdated;
    final lOther$progressUpdated = other.progressUpdated;
    if (l$progressUpdated != lOther$progressUpdated) {
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

extension UtilityExtension$Subscription$ProgressUpdated
    on Subscription$ProgressUpdated {
  CopyWith$Subscription$ProgressUpdated<Subscription$ProgressUpdated>
      get copyWith => CopyWith$Subscription$ProgressUpdated(this, (i) => i);
}

abstract class CopyWith$Subscription$ProgressUpdated<TRes> {
  factory CopyWith$Subscription$ProgressUpdated(
    Subscription$ProgressUpdated instance,
    TRes Function(Subscription$ProgressUpdated) then,
  ) = _CopyWithImpl$Subscription$ProgressUpdated;

  factory CopyWith$Subscription$ProgressUpdated.stub(TRes res) =
      _CopyWithStubImpl$Subscription$ProgressUpdated;

  TRes call({Fragment$ProgressFragment? progressUpdated, String? $__typename});
  CopyWith$Fragment$ProgressFragment<TRes> get progressUpdated;
}

class _CopyWithImpl$Subscription$ProgressUpdated<TRes>
    implements CopyWith$Subscription$ProgressUpdated<TRes> {
  _CopyWithImpl$Subscription$ProgressUpdated(this._instance, this._then);

  final Subscription$ProgressUpdated _instance;

  final TRes Function(Subscription$ProgressUpdated) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? progressUpdated = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Subscription$ProgressUpdated(
          progressUpdated: progressUpdated == _undefined
              ? _instance.progressUpdated
              : (progressUpdated as Fragment$ProgressFragment?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Fragment$ProgressFragment<TRes> get progressUpdated {
    final local$progressUpdated = _instance.progressUpdated;
    return local$progressUpdated == null
        ? CopyWith$Fragment$ProgressFragment.stub(_then(_instance))
        : CopyWith$Fragment$ProgressFragment(
            local$progressUpdated,
            (e) => call(progressUpdated: e),
          );
  }
}

class _CopyWithStubImpl$Subscription$ProgressUpdated<TRes>
    implements CopyWith$Subscription$ProgressUpdated<TRes> {
  _CopyWithStubImpl$Subscription$ProgressUpdated(this._res);

  TRes _res;

  call({Fragment$ProgressFragment? progressUpdated, String? $__typename}) =>
      _res;

  CopyWith$Fragment$ProgressFragment<TRes> get progressUpdated =>
      CopyWith$Fragment$ProgressFragment.stub(_res);
}

const documentNodeSubscriptionProgressUpdated = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.subscription,
      name: NameNode(value: 'ProgressUpdated'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'nodeId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'progressUpdated'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'nodeId'),
                value: VariableNode(name: NameNode(value: 'nodeId')),
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
