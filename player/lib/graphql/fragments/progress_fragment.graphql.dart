import 'package:gql/ast.dart';

class Fragment$ProgressFragment {
  Fragment$ProgressFragment({
    required this.positionSeconds,
    this.durationSeconds,
    this.percentage,
    required this.watched,
    this.lastWatchedAt,
    this.$__typename = 'Progress',
  });

  factory Fragment$ProgressFragment.fromJson(Map<String, dynamic> json) {
    final l$positionSeconds = json['positionSeconds'];
    final l$durationSeconds = json['durationSeconds'];
    final l$percentage = json['percentage'];
    final l$watched = json['watched'];
    final l$lastWatchedAt = json['lastWatchedAt'];
    final l$$__typename = json['__typename'];
    return Fragment$ProgressFragment(
      positionSeconds: (l$positionSeconds as int),
      durationSeconds: (l$durationSeconds as int?),
      percentage: (l$percentage as num?)?.toDouble(),
      watched: (l$watched as bool),
      lastWatchedAt: (l$lastWatchedAt as String?),
      $__typename: (l$$__typename as String),
    );
  }

  final int positionSeconds;

  final int? durationSeconds;

  final double? percentage;

  final bool watched;

  final String? lastWatchedAt;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$positionSeconds = positionSeconds;
    _resultData['positionSeconds'] = l$positionSeconds;
    final l$durationSeconds = durationSeconds;
    _resultData['durationSeconds'] = l$durationSeconds;
    final l$percentage = percentage;
    _resultData['percentage'] = l$percentage;
    final l$watched = watched;
    _resultData['watched'] = l$watched;
    final l$lastWatchedAt = lastWatchedAt;
    _resultData['lastWatchedAt'] = l$lastWatchedAt;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$positionSeconds = positionSeconds;
    final l$durationSeconds = durationSeconds;
    final l$percentage = percentage;
    final l$watched = watched;
    final l$lastWatchedAt = lastWatchedAt;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$positionSeconds,
      l$durationSeconds,
      l$percentage,
      l$watched,
      l$lastWatchedAt,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Fragment$ProgressFragment ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$positionSeconds = positionSeconds;
    final lOther$positionSeconds = other.positionSeconds;
    if (l$positionSeconds != lOther$positionSeconds) {
      return false;
    }
    final l$durationSeconds = durationSeconds;
    final lOther$durationSeconds = other.durationSeconds;
    if (l$durationSeconds != lOther$durationSeconds) {
      return false;
    }
    final l$percentage = percentage;
    final lOther$percentage = other.percentage;
    if (l$percentage != lOther$percentage) {
      return false;
    }
    final l$watched = watched;
    final lOther$watched = other.watched;
    if (l$watched != lOther$watched) {
      return false;
    }
    final l$lastWatchedAt = lastWatchedAt;
    final lOther$lastWatchedAt = other.lastWatchedAt;
    if (l$lastWatchedAt != lOther$lastWatchedAt) {
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

extension UtilityExtension$Fragment$ProgressFragment
    on Fragment$ProgressFragment {
  CopyWith$Fragment$ProgressFragment<Fragment$ProgressFragment> get copyWith =>
      CopyWith$Fragment$ProgressFragment(this, (i) => i);
}

abstract class CopyWith$Fragment$ProgressFragment<TRes> {
  factory CopyWith$Fragment$ProgressFragment(
    Fragment$ProgressFragment instance,
    TRes Function(Fragment$ProgressFragment) then,
  ) = _CopyWithImpl$Fragment$ProgressFragment;

  factory CopyWith$Fragment$ProgressFragment.stub(TRes res) =
      _CopyWithStubImpl$Fragment$ProgressFragment;

  TRes call({
    int? positionSeconds,
    int? durationSeconds,
    double? percentage,
    bool? watched,
    String? lastWatchedAt,
    String? $__typename,
  });
}

class _CopyWithImpl$Fragment$ProgressFragment<TRes>
    implements CopyWith$Fragment$ProgressFragment<TRes> {
  _CopyWithImpl$Fragment$ProgressFragment(this._instance, this._then);

  final Fragment$ProgressFragment _instance;

  final TRes Function(Fragment$ProgressFragment) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? positionSeconds = _undefined,
    Object? durationSeconds = _undefined,
    Object? percentage = _undefined,
    Object? watched = _undefined,
    Object? lastWatchedAt = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Fragment$ProgressFragment(
          positionSeconds:
              positionSeconds == _undefined || positionSeconds == null
                  ? _instance.positionSeconds
                  : (positionSeconds as int),
          durationSeconds: durationSeconds == _undefined
              ? _instance.durationSeconds
              : (durationSeconds as int?),
          percentage: percentage == _undefined
              ? _instance.percentage
              : (percentage as double?),
          watched: watched == _undefined || watched == null
              ? _instance.watched
              : (watched as bool),
          lastWatchedAt: lastWatchedAt == _undefined
              ? _instance.lastWatchedAt
              : (lastWatchedAt as String?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Fragment$ProgressFragment<TRes>
    implements CopyWith$Fragment$ProgressFragment<TRes> {
  _CopyWithStubImpl$Fragment$ProgressFragment(this._res);

  TRes _res;

  call({
    int? positionSeconds,
    int? durationSeconds,
    double? percentage,
    bool? watched,
    String? lastWatchedAt,
    String? $__typename,
  }) =>
      _res;
}

const fragmentDefinitionProgressFragment = FragmentDefinitionNode(
  name: NameNode(value: 'ProgressFragment'),
  typeCondition: TypeConditionNode(
    on: NamedTypeNode(name: NameNode(value: 'Progress'), isNonNull: false),
  ),
  directives: [],
  selectionSet: SelectionSetNode(
    selections: [
      FieldNode(
        name: NameNode(value: 'positionSeconds'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'durationSeconds'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'percentage'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'watched'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'lastWatchedAt'),
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
);
const documentNodeFragmentProgressFragment = DocumentNode(
  definitions: [fragmentDefinitionProgressFragment],
);
