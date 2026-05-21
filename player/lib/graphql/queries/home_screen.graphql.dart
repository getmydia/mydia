import '../fragments/artwork_fragment.graphql.dart';
import '../fragments/progress_fragment.graphql.dart';
import '../schema.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Query$HomeScreen {
  factory Variables$Query$HomeScreen({
    int? continueWatchingLimit,
    int? recentlyAddedLimit,
    int? upNextLimit,
  }) =>
      Variables$Query$HomeScreen._({
        if (continueWatchingLimit != null)
          r'continueWatchingLimit': continueWatchingLimit,
        if (recentlyAddedLimit != null)
          r'recentlyAddedLimit': recentlyAddedLimit,
        if (upNextLimit != null) r'upNextLimit': upNextLimit,
      });

  Variables$Query$HomeScreen._(this._$data);

  factory Variables$Query$HomeScreen.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    if (data.containsKey('continueWatchingLimit')) {
      final l$continueWatchingLimit = data['continueWatchingLimit'];
      result$data['continueWatchingLimit'] = (l$continueWatchingLimit as int?);
    }
    if (data.containsKey('recentlyAddedLimit')) {
      final l$recentlyAddedLimit = data['recentlyAddedLimit'];
      result$data['recentlyAddedLimit'] = (l$recentlyAddedLimit as int?);
    }
    if (data.containsKey('upNextLimit')) {
      final l$upNextLimit = data['upNextLimit'];
      result$data['upNextLimit'] = (l$upNextLimit as int?);
    }
    return Variables$Query$HomeScreen._(result$data);
  }

  Map<String, dynamic> _$data;

  int? get continueWatchingLimit => (_$data['continueWatchingLimit'] as int?);

  int? get recentlyAddedLimit => (_$data['recentlyAddedLimit'] as int?);

  int? get upNextLimit => (_$data['upNextLimit'] as int?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    if (_$data.containsKey('continueWatchingLimit')) {
      final l$continueWatchingLimit = continueWatchingLimit;
      result$data['continueWatchingLimit'] = l$continueWatchingLimit;
    }
    if (_$data.containsKey('recentlyAddedLimit')) {
      final l$recentlyAddedLimit = recentlyAddedLimit;
      result$data['recentlyAddedLimit'] = l$recentlyAddedLimit;
    }
    if (_$data.containsKey('upNextLimit')) {
      final l$upNextLimit = upNextLimit;
      result$data['upNextLimit'] = l$upNextLimit;
    }
    return result$data;
  }

  CopyWith$Variables$Query$HomeScreen<Variables$Query$HomeScreen>
      get copyWith => CopyWith$Variables$Query$HomeScreen(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Query$HomeScreen ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$continueWatchingLimit = continueWatchingLimit;
    final lOther$continueWatchingLimit = other.continueWatchingLimit;
    if (_$data.containsKey('continueWatchingLimit') !=
        other._$data.containsKey('continueWatchingLimit')) {
      return false;
    }
    if (l$continueWatchingLimit != lOther$continueWatchingLimit) {
      return false;
    }
    final l$recentlyAddedLimit = recentlyAddedLimit;
    final lOther$recentlyAddedLimit = other.recentlyAddedLimit;
    if (_$data.containsKey('recentlyAddedLimit') !=
        other._$data.containsKey('recentlyAddedLimit')) {
      return false;
    }
    if (l$recentlyAddedLimit != lOther$recentlyAddedLimit) {
      return false;
    }
    final l$upNextLimit = upNextLimit;
    final lOther$upNextLimit = other.upNextLimit;
    if (_$data.containsKey('upNextLimit') !=
        other._$data.containsKey('upNextLimit')) {
      return false;
    }
    if (l$upNextLimit != lOther$upNextLimit) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$continueWatchingLimit = continueWatchingLimit;
    final l$recentlyAddedLimit = recentlyAddedLimit;
    final l$upNextLimit = upNextLimit;
    return Object.hashAll([
      _$data.containsKey('continueWatchingLimit')
          ? l$continueWatchingLimit
          : const {},
      _$data.containsKey('recentlyAddedLimit')
          ? l$recentlyAddedLimit
          : const {},
      _$data.containsKey('upNextLimit') ? l$upNextLimit : const {},
    ]);
  }
}

abstract class CopyWith$Variables$Query$HomeScreen<TRes> {
  factory CopyWith$Variables$Query$HomeScreen(
    Variables$Query$HomeScreen instance,
    TRes Function(Variables$Query$HomeScreen) then,
  ) = _CopyWithImpl$Variables$Query$HomeScreen;

  factory CopyWith$Variables$Query$HomeScreen.stub(TRes res) =
      _CopyWithStubImpl$Variables$Query$HomeScreen;

  TRes call({
    int? continueWatchingLimit,
    int? recentlyAddedLimit,
    int? upNextLimit,
  });
}

class _CopyWithImpl$Variables$Query$HomeScreen<TRes>
    implements CopyWith$Variables$Query$HomeScreen<TRes> {
  _CopyWithImpl$Variables$Query$HomeScreen(this._instance, this._then);

  final Variables$Query$HomeScreen _instance;

  final TRes Function(Variables$Query$HomeScreen) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? continueWatchingLimit = _undefined,
    Object? recentlyAddedLimit = _undefined,
    Object? upNextLimit = _undefined,
  }) =>
      _then(
        Variables$Query$HomeScreen._({
          ..._instance._$data,
          if (continueWatchingLimit != _undefined)
            'continueWatchingLimit': (continueWatchingLimit as int?),
          if (recentlyAddedLimit != _undefined)
            'recentlyAddedLimit': (recentlyAddedLimit as int?),
          if (upNextLimit != _undefined) 'upNextLimit': (upNextLimit as int?),
        }),
      );
}

class _CopyWithStubImpl$Variables$Query$HomeScreen<TRes>
    implements CopyWith$Variables$Query$HomeScreen<TRes> {
  _CopyWithStubImpl$Variables$Query$HomeScreen(this._res);

  TRes _res;

  call({
    int? continueWatchingLimit,
    int? recentlyAddedLimit,
    int? upNextLimit,
  }) =>
      _res;
}

class Query$HomeScreen {
  Query$HomeScreen({
    this.continueWatching,
    this.recentlyAdded,
    this.upNext,
    this.trending,
    this.$__typename = 'RootQueryType',
  });

  factory Query$HomeScreen.fromJson(Map<String, dynamic> json) {
    final l$continueWatching = json['continueWatching'];
    final l$recentlyAdded = json['recentlyAdded'];
    final l$upNext = json['upNext'];
    final l$trending = json['trending'];
    final l$$__typename = json['__typename'];
    return Query$HomeScreen(
      continueWatching: (l$continueWatching as List<dynamic>?)
          ?.map(
            (e) => e == null
                ? null
                : Query$HomeScreen$continueWatching.fromJson(
                    (e as Map<String, dynamic>),
                  ),
          )
          .toList(),
      recentlyAdded: (l$recentlyAdded as List<dynamic>?)
          ?.map(
            (e) => e == null
                ? null
                : Query$HomeScreen$recentlyAdded.fromJson(
                    (e as Map<String, dynamic>),
                  ),
          )
          .toList(),
      upNext: (l$upNext as List<dynamic>?)
          ?.map(
            (e) => e == null
                ? null
                : Query$HomeScreen$upNext.fromJson((e as Map<String, dynamic>)),
          )
          .toList(),
      trending: (l$trending as List<dynamic>?)
          ?.map(
            (e) => e == null
                ? null
                : Query$HomeScreen$trending.fromJson(
                    (e as Map<String, dynamic>),
                  ),
          )
          .toList(),
      $__typename: (l$$__typename as String),
    );
  }

  final List<Query$HomeScreen$continueWatching?>? continueWatching;

  final List<Query$HomeScreen$recentlyAdded?>? recentlyAdded;

  final List<Query$HomeScreen$upNext?>? upNext;

  final List<Query$HomeScreen$trending?>? trending;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$continueWatching = continueWatching;
    _resultData['continueWatching'] =
        l$continueWatching?.map((e) => e?.toJson()).toList();
    final l$recentlyAdded = recentlyAdded;
    _resultData['recentlyAdded'] =
        l$recentlyAdded?.map((e) => e?.toJson()).toList();
    final l$upNext = upNext;
    _resultData['upNext'] = l$upNext?.map((e) => e?.toJson()).toList();
    final l$trending = trending;
    _resultData['trending'] = l$trending?.map((e) => e?.toJson()).toList();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$continueWatching = continueWatching;
    final l$recentlyAdded = recentlyAdded;
    final l$upNext = upNext;
    final l$trending = trending;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$continueWatching == null
          ? null
          : Object.hashAll(l$continueWatching.map((v) => v)),
      l$recentlyAdded == null
          ? null
          : Object.hashAll(l$recentlyAdded.map((v) => v)),
      l$upNext == null ? null : Object.hashAll(l$upNext.map((v) => v)),
      l$trending == null ? null : Object.hashAll(l$trending.map((v) => v)),
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$HomeScreen || runtimeType != other.runtimeType) {
      return false;
    }
    final l$continueWatching = continueWatching;
    final lOther$continueWatching = other.continueWatching;
    if (l$continueWatching != null && lOther$continueWatching != null) {
      if (l$continueWatching.length != lOther$continueWatching.length) {
        return false;
      }
      for (int i = 0; i < l$continueWatching.length; i++) {
        final l$continueWatching$entry = l$continueWatching[i];
        final lOther$continueWatching$entry = lOther$continueWatching[i];
        if (l$continueWatching$entry != lOther$continueWatching$entry) {
          return false;
        }
      }
    } else if (l$continueWatching != lOther$continueWatching) {
      return false;
    }
    final l$recentlyAdded = recentlyAdded;
    final lOther$recentlyAdded = other.recentlyAdded;
    if (l$recentlyAdded != null && lOther$recentlyAdded != null) {
      if (l$recentlyAdded.length != lOther$recentlyAdded.length) {
        return false;
      }
      for (int i = 0; i < l$recentlyAdded.length; i++) {
        final l$recentlyAdded$entry = l$recentlyAdded[i];
        final lOther$recentlyAdded$entry = lOther$recentlyAdded[i];
        if (l$recentlyAdded$entry != lOther$recentlyAdded$entry) {
          return false;
        }
      }
    } else if (l$recentlyAdded != lOther$recentlyAdded) {
      return false;
    }
    final l$upNext = upNext;
    final lOther$upNext = other.upNext;
    if (l$upNext != null && lOther$upNext != null) {
      if (l$upNext.length != lOther$upNext.length) {
        return false;
      }
      for (int i = 0; i < l$upNext.length; i++) {
        final l$upNext$entry = l$upNext[i];
        final lOther$upNext$entry = lOther$upNext[i];
        if (l$upNext$entry != lOther$upNext$entry) {
          return false;
        }
      }
    } else if (l$upNext != lOther$upNext) {
      return false;
    }
    final l$trending = trending;
    final lOther$trending = other.trending;
    if (l$trending != null && lOther$trending != null) {
      if (l$trending.length != lOther$trending.length) {
        return false;
      }
      for (int i = 0; i < l$trending.length; i++) {
        final l$trending$entry = l$trending[i];
        final lOther$trending$entry = lOther$trending[i];
        if (l$trending$entry != lOther$trending$entry) {
          return false;
        }
      }
    } else if (l$trending != lOther$trending) {
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

extension UtilityExtension$Query$HomeScreen on Query$HomeScreen {
  CopyWith$Query$HomeScreen<Query$HomeScreen> get copyWith =>
      CopyWith$Query$HomeScreen(this, (i) => i);
}

abstract class CopyWith$Query$HomeScreen<TRes> {
  factory CopyWith$Query$HomeScreen(
    Query$HomeScreen instance,
    TRes Function(Query$HomeScreen) then,
  ) = _CopyWithImpl$Query$HomeScreen;

  factory CopyWith$Query$HomeScreen.stub(TRes res) =
      _CopyWithStubImpl$Query$HomeScreen;

  TRes call({
    List<Query$HomeScreen$continueWatching?>? continueWatching,
    List<Query$HomeScreen$recentlyAdded?>? recentlyAdded,
    List<Query$HomeScreen$upNext?>? upNext,
    List<Query$HomeScreen$trending?>? trending,
    String? $__typename,
  });
  TRes continueWatching(
    Iterable<Query$HomeScreen$continueWatching?>? Function(
      Iterable<
          CopyWith$Query$HomeScreen$continueWatching<
              Query$HomeScreen$continueWatching>?>?,
    ) _fn,
  );
  TRes recentlyAdded(
    Iterable<Query$HomeScreen$recentlyAdded?>? Function(
      Iterable<
          CopyWith$Query$HomeScreen$recentlyAdded<
              Query$HomeScreen$recentlyAdded>?>?,
    ) _fn,
  );
  TRes upNext(
    Iterable<Query$HomeScreen$upNext?>? Function(
      Iterable<CopyWith$Query$HomeScreen$upNext<Query$HomeScreen$upNext>?>?,
    ) _fn,
  );
  TRes trending(
    Iterable<Query$HomeScreen$trending?>? Function(
      Iterable<CopyWith$Query$HomeScreen$trending<Query$HomeScreen$trending>?>?,
    ) _fn,
  );
}

class _CopyWithImpl$Query$HomeScreen<TRes>
    implements CopyWith$Query$HomeScreen<TRes> {
  _CopyWithImpl$Query$HomeScreen(this._instance, this._then);

  final Query$HomeScreen _instance;

  final TRes Function(Query$HomeScreen) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? continueWatching = _undefined,
    Object? recentlyAdded = _undefined,
    Object? upNext = _undefined,
    Object? trending = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$HomeScreen(
          continueWatching: continueWatching == _undefined
              ? _instance.continueWatching
              : (continueWatching as List<Query$HomeScreen$continueWatching?>?),
          recentlyAdded: recentlyAdded == _undefined
              ? _instance.recentlyAdded
              : (recentlyAdded as List<Query$HomeScreen$recentlyAdded?>?),
          upNext: upNext == _undefined
              ? _instance.upNext
              : (upNext as List<Query$HomeScreen$upNext?>?),
          trending: trending == _undefined
              ? _instance.trending
              : (trending as List<Query$HomeScreen$trending?>?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  TRes continueWatching(
    Iterable<Query$HomeScreen$continueWatching?>? Function(
      Iterable<
          CopyWith$Query$HomeScreen$continueWatching<
              Query$HomeScreen$continueWatching>?>?,
    ) _fn,
  ) =>
      call(
        continueWatching: _fn(
          _instance.continueWatching?.map(
            (e) => e == null
                ? null
                : CopyWith$Query$HomeScreen$continueWatching(e, (i) => i),
          ),
        )?.toList(),
      );

  TRes recentlyAdded(
    Iterable<Query$HomeScreen$recentlyAdded?>? Function(
      Iterable<
          CopyWith$Query$HomeScreen$recentlyAdded<
              Query$HomeScreen$recentlyAdded>?>?,
    ) _fn,
  ) =>
      call(
        recentlyAdded: _fn(
          _instance.recentlyAdded?.map(
            (e) => e == null
                ? null
                : CopyWith$Query$HomeScreen$recentlyAdded(e, (i) => i),
          ),
        )?.toList(),
      );

  TRes upNext(
    Iterable<Query$HomeScreen$upNext?>? Function(
      Iterable<CopyWith$Query$HomeScreen$upNext<Query$HomeScreen$upNext>?>?,
    ) _fn,
  ) =>
      call(
        upNext: _fn(
          _instance.upNext?.map(
            (e) => e == null
                ? null
                : CopyWith$Query$HomeScreen$upNext(e, (i) => i),
          ),
        )?.toList(),
      );

  TRes trending(
    Iterable<Query$HomeScreen$trending?>? Function(
      Iterable<CopyWith$Query$HomeScreen$trending<Query$HomeScreen$trending>?>?,
    ) _fn,
  ) =>
      call(
        trending: _fn(
          _instance.trending?.map(
            (e) => e == null
                ? null
                : CopyWith$Query$HomeScreen$trending(e, (i) => i),
          ),
        )?.toList(),
      );
}

class _CopyWithStubImpl$Query$HomeScreen<TRes>
    implements CopyWith$Query$HomeScreen<TRes> {
  _CopyWithStubImpl$Query$HomeScreen(this._res);

  TRes _res;

  call({
    List<Query$HomeScreen$continueWatching?>? continueWatching,
    List<Query$HomeScreen$recentlyAdded?>? recentlyAdded,
    List<Query$HomeScreen$upNext?>? upNext,
    List<Query$HomeScreen$trending?>? trending,
    String? $__typename,
  }) =>
      _res;

  continueWatching(_fn) => _res;

  recentlyAdded(_fn) => _res;

  upNext(_fn) => _res;

  trending(_fn) => _res;
}

const documentNodeQueryHomeScreen = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.query,
      name: NameNode(value: 'HomeScreen'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(
            name: NameNode(value: 'continueWatchingLimit'),
          ),
          type: NamedTypeNode(name: NameNode(value: 'Int'), isNonNull: false),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'recentlyAddedLimit')),
          type: NamedTypeNode(name: NameNode(value: 'Int'), isNonNull: false),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'upNextLimit')),
          type: NamedTypeNode(name: NameNode(value: 'Int'), isNonNull: false),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'continueWatching'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'first'),
                value: VariableNode(
                  name: NameNode(value: 'continueWatchingLimit'),
                ),
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
                  name: NameNode(value: 'type'),
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
                  name: NameNode(value: 'artwork'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: SelectionSetNode(
                    selections: [
                      FragmentSpreadNode(
                        name: NameNode(value: 'ArtworkFragment'),
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
                  name: NameNode(value: 'progress'),
                  alias: null,
                  arguments: [],
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
                  name: NameNode(value: 'showId'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'showTitle'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'seasonNumber'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'episodeNumber'),
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
            name: NameNode(value: 'recentlyAdded'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'first'),
                value: VariableNode(
                  name: NameNode(value: 'recentlyAddedLimit'),
                ),
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
                  name: NameNode(value: 'type'),
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
                  name: NameNode(value: 'year'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'artwork'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: SelectionSetNode(
                    selections: [
                      FragmentSpreadNode(
                        name: NameNode(value: 'ArtworkFragment'),
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
                  name: NameNode(value: 'addedAt'),
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
            name: NameNode(value: 'upNext'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'first'),
                value: VariableNode(name: NameNode(value: 'upNextLimit')),
              ),
            ],
            directives: [],
            selectionSet: SelectionSetNode(
              selections: [
                FieldNode(
                  name: NameNode(value: 'progressState'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'episode'),
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
                        name: NameNode(value: 'seasonNumber'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'episodeNumber'),
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
                        name: NameNode(value: 'airDate'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'thumbnailUrl'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'hasFile'),
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
                  name: NameNode(value: 'show'),
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
                        name: NameNode(value: 'title'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'artwork'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: SelectionSetNode(
                          selections: [
                            FragmentSpreadNode(
                              name: NameNode(value: 'ArtworkFragment'),
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
            name: NameNode(value: 'trending'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'type'),
                value: EnumValueNode(name: NameNode(value: 'MOVIE')),
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
                  name: NameNode(value: 'type'),
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
                  name: NameNode(value: 'year'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'artwork'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: SelectionSetNode(
                    selections: [
                      FragmentSpreadNode(
                        name: NameNode(value: 'ArtworkFragment'),
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
    fragmentDefinitionArtworkFragment,
    fragmentDefinitionProgressFragment,
  ],
);

class Query$HomeScreen$continueWatching {
  Query$HomeScreen$continueWatching({
    required this.id,
    required this.type,
    required this.title,
    this.artwork,
    required this.progress,
    this.showId,
    this.showTitle,
    this.seasonNumber,
    this.episodeNumber,
    this.$__typename = 'ContinueWatchingItem',
  });

  factory Query$HomeScreen$continueWatching.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$type = json['type'];
    final l$title = json['title'];
    final l$artwork = json['artwork'];
    final l$progress = json['progress'];
    final l$showId = json['showId'];
    final l$showTitle = json['showTitle'];
    final l$seasonNumber = json['seasonNumber'];
    final l$episodeNumber = json['episodeNumber'];
    final l$$__typename = json['__typename'];
    return Query$HomeScreen$continueWatching(
      id: (l$id as String),
      type: fromJson$Enum$MediaType((l$type as String)),
      title: (l$title as String),
      artwork: l$artwork == null
          ? null
          : Fragment$ArtworkFragment.fromJson(
              (l$artwork as Map<String, dynamic>),
            ),
      progress: Fragment$ProgressFragment.fromJson(
        (l$progress as Map<String, dynamic>),
      ),
      showId: (l$showId as String?),
      showTitle: (l$showTitle as String?),
      seasonNumber: (l$seasonNumber as int?),
      episodeNumber: (l$episodeNumber as int?),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final Enum$MediaType type;

  final String title;

  final Fragment$ArtworkFragment? artwork;

  final Fragment$ProgressFragment progress;

  final String? showId;

  final String? showTitle;

  final int? seasonNumber;

  final int? episodeNumber;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$type = type;
    _resultData['type'] = toJson$Enum$MediaType(l$type);
    final l$title = title;
    _resultData['title'] = l$title;
    final l$artwork = artwork;
    _resultData['artwork'] = l$artwork?.toJson();
    final l$progress = progress;
    _resultData['progress'] = l$progress.toJson();
    final l$showId = showId;
    _resultData['showId'] = l$showId;
    final l$showTitle = showTitle;
    _resultData['showTitle'] = l$showTitle;
    final l$seasonNumber = seasonNumber;
    _resultData['seasonNumber'] = l$seasonNumber;
    final l$episodeNumber = episodeNumber;
    _resultData['episodeNumber'] = l$episodeNumber;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$type = type;
    final l$title = title;
    final l$artwork = artwork;
    final l$progress = progress;
    final l$showId = showId;
    final l$showTitle = showTitle;
    final l$seasonNumber = seasonNumber;
    final l$episodeNumber = episodeNumber;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$type,
      l$title,
      l$artwork,
      l$progress,
      l$showId,
      l$showTitle,
      l$seasonNumber,
      l$episodeNumber,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$HomeScreen$continueWatching ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$type = type;
    final lOther$type = other.type;
    if (l$type != lOther$type) {
      return false;
    }
    final l$title = title;
    final lOther$title = other.title;
    if (l$title != lOther$title) {
      return false;
    }
    final l$artwork = artwork;
    final lOther$artwork = other.artwork;
    if (l$artwork != lOther$artwork) {
      return false;
    }
    final l$progress = progress;
    final lOther$progress = other.progress;
    if (l$progress != lOther$progress) {
      return false;
    }
    final l$showId = showId;
    final lOther$showId = other.showId;
    if (l$showId != lOther$showId) {
      return false;
    }
    final l$showTitle = showTitle;
    final lOther$showTitle = other.showTitle;
    if (l$showTitle != lOther$showTitle) {
      return false;
    }
    final l$seasonNumber = seasonNumber;
    final lOther$seasonNumber = other.seasonNumber;
    if (l$seasonNumber != lOther$seasonNumber) {
      return false;
    }
    final l$episodeNumber = episodeNumber;
    final lOther$episodeNumber = other.episodeNumber;
    if (l$episodeNumber != lOther$episodeNumber) {
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

extension UtilityExtension$Query$HomeScreen$continueWatching
    on Query$HomeScreen$continueWatching {
  CopyWith$Query$HomeScreen$continueWatching<Query$HomeScreen$continueWatching>
      get copyWith =>
          CopyWith$Query$HomeScreen$continueWatching(this, (i) => i);
}

abstract class CopyWith$Query$HomeScreen$continueWatching<TRes> {
  factory CopyWith$Query$HomeScreen$continueWatching(
    Query$HomeScreen$continueWatching instance,
    TRes Function(Query$HomeScreen$continueWatching) then,
  ) = _CopyWithImpl$Query$HomeScreen$continueWatching;

  factory CopyWith$Query$HomeScreen$continueWatching.stub(TRes res) =
      _CopyWithStubImpl$Query$HomeScreen$continueWatching;

  TRes call({
    String? id,
    Enum$MediaType? type,
    String? title,
    Fragment$ArtworkFragment? artwork,
    Fragment$ProgressFragment? progress,
    String? showId,
    String? showTitle,
    int? seasonNumber,
    int? episodeNumber,
    String? $__typename,
  });
  CopyWith$Fragment$ArtworkFragment<TRes> get artwork;
  CopyWith$Fragment$ProgressFragment<TRes> get progress;
}

class _CopyWithImpl$Query$HomeScreen$continueWatching<TRes>
    implements CopyWith$Query$HomeScreen$continueWatching<TRes> {
  _CopyWithImpl$Query$HomeScreen$continueWatching(this._instance, this._then);

  final Query$HomeScreen$continueWatching _instance;

  final TRes Function(Query$HomeScreen$continueWatching) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? type = _undefined,
    Object? title = _undefined,
    Object? artwork = _undefined,
    Object? progress = _undefined,
    Object? showId = _undefined,
    Object? showTitle = _undefined,
    Object? seasonNumber = _undefined,
    Object? episodeNumber = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$HomeScreen$continueWatching(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          type: type == _undefined || type == null
              ? _instance.type
              : (type as Enum$MediaType),
          title: title == _undefined || title == null
              ? _instance.title
              : (title as String),
          artwork: artwork == _undefined
              ? _instance.artwork
              : (artwork as Fragment$ArtworkFragment?),
          progress: progress == _undefined || progress == null
              ? _instance.progress
              : (progress as Fragment$ProgressFragment),
          showId: showId == _undefined ? _instance.showId : (showId as String?),
          showTitle: showTitle == _undefined
              ? _instance.showTitle
              : (showTitle as String?),
          seasonNumber: seasonNumber == _undefined
              ? _instance.seasonNumber
              : (seasonNumber as int?),
          episodeNumber: episodeNumber == _undefined
              ? _instance.episodeNumber
              : (episodeNumber as int?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork {
    final local$artwork = _instance.artwork;
    return local$artwork == null
        ? CopyWith$Fragment$ArtworkFragment.stub(_then(_instance))
        : CopyWith$Fragment$ArtworkFragment(
            local$artwork,
            (e) => call(artwork: e),
          );
  }

  CopyWith$Fragment$ProgressFragment<TRes> get progress {
    final local$progress = _instance.progress;
    return CopyWith$Fragment$ProgressFragment(
      local$progress,
      (e) => call(progress: e),
    );
  }
}

class _CopyWithStubImpl$Query$HomeScreen$continueWatching<TRes>
    implements CopyWith$Query$HomeScreen$continueWatching<TRes> {
  _CopyWithStubImpl$Query$HomeScreen$continueWatching(this._res);

  TRes _res;

  call({
    String? id,
    Enum$MediaType? type,
    String? title,
    Fragment$ArtworkFragment? artwork,
    Fragment$ProgressFragment? progress,
    String? showId,
    String? showTitle,
    int? seasonNumber,
    int? episodeNumber,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork =>
      CopyWith$Fragment$ArtworkFragment.stub(_res);

  CopyWith$Fragment$ProgressFragment<TRes> get progress =>
      CopyWith$Fragment$ProgressFragment.stub(_res);
}

class Query$HomeScreen$recentlyAdded {
  Query$HomeScreen$recentlyAdded({
    required this.id,
    required this.type,
    required this.title,
    this.year,
    this.artwork,
    required this.addedAt,
    this.$__typename = 'RecentlyAddedItem',
  });

  factory Query$HomeScreen$recentlyAdded.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$type = json['type'];
    final l$title = json['title'];
    final l$year = json['year'];
    final l$artwork = json['artwork'];
    final l$addedAt = json['addedAt'];
    final l$$__typename = json['__typename'];
    return Query$HomeScreen$recentlyAdded(
      id: (l$id as String),
      type: fromJson$Enum$MediaType((l$type as String)),
      title: (l$title as String),
      year: (l$year as int?),
      artwork: l$artwork == null
          ? null
          : Fragment$ArtworkFragment.fromJson(
              (l$artwork as Map<String, dynamic>),
            ),
      addedAt: (l$addedAt as String),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final Enum$MediaType type;

  final String title;

  final int? year;

  final Fragment$ArtworkFragment? artwork;

  final String addedAt;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$type = type;
    _resultData['type'] = toJson$Enum$MediaType(l$type);
    final l$title = title;
    _resultData['title'] = l$title;
    final l$year = year;
    _resultData['year'] = l$year;
    final l$artwork = artwork;
    _resultData['artwork'] = l$artwork?.toJson();
    final l$addedAt = addedAt;
    _resultData['addedAt'] = l$addedAt;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$type = type;
    final l$title = title;
    final l$year = year;
    final l$artwork = artwork;
    final l$addedAt = addedAt;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$type,
      l$title,
      l$year,
      l$artwork,
      l$addedAt,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$HomeScreen$recentlyAdded ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$type = type;
    final lOther$type = other.type;
    if (l$type != lOther$type) {
      return false;
    }
    final l$title = title;
    final lOther$title = other.title;
    if (l$title != lOther$title) {
      return false;
    }
    final l$year = year;
    final lOther$year = other.year;
    if (l$year != lOther$year) {
      return false;
    }
    final l$artwork = artwork;
    final lOther$artwork = other.artwork;
    if (l$artwork != lOther$artwork) {
      return false;
    }
    final l$addedAt = addedAt;
    final lOther$addedAt = other.addedAt;
    if (l$addedAt != lOther$addedAt) {
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

extension UtilityExtension$Query$HomeScreen$recentlyAdded
    on Query$HomeScreen$recentlyAdded {
  CopyWith$Query$HomeScreen$recentlyAdded<Query$HomeScreen$recentlyAdded>
      get copyWith => CopyWith$Query$HomeScreen$recentlyAdded(this, (i) => i);
}

abstract class CopyWith$Query$HomeScreen$recentlyAdded<TRes> {
  factory CopyWith$Query$HomeScreen$recentlyAdded(
    Query$HomeScreen$recentlyAdded instance,
    TRes Function(Query$HomeScreen$recentlyAdded) then,
  ) = _CopyWithImpl$Query$HomeScreen$recentlyAdded;

  factory CopyWith$Query$HomeScreen$recentlyAdded.stub(TRes res) =
      _CopyWithStubImpl$Query$HomeScreen$recentlyAdded;

  TRes call({
    String? id,
    Enum$MediaType? type,
    String? title,
    int? year,
    Fragment$ArtworkFragment? artwork,
    String? addedAt,
    String? $__typename,
  });
  CopyWith$Fragment$ArtworkFragment<TRes> get artwork;
}

class _CopyWithImpl$Query$HomeScreen$recentlyAdded<TRes>
    implements CopyWith$Query$HomeScreen$recentlyAdded<TRes> {
  _CopyWithImpl$Query$HomeScreen$recentlyAdded(this._instance, this._then);

  final Query$HomeScreen$recentlyAdded _instance;

  final TRes Function(Query$HomeScreen$recentlyAdded) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? type = _undefined,
    Object? title = _undefined,
    Object? year = _undefined,
    Object? artwork = _undefined,
    Object? addedAt = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$HomeScreen$recentlyAdded(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          type: type == _undefined || type == null
              ? _instance.type
              : (type as Enum$MediaType),
          title: title == _undefined || title == null
              ? _instance.title
              : (title as String),
          year: year == _undefined ? _instance.year : (year as int?),
          artwork: artwork == _undefined
              ? _instance.artwork
              : (artwork as Fragment$ArtworkFragment?),
          addedAt: addedAt == _undefined || addedAt == null
              ? _instance.addedAt
              : (addedAt as String),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork {
    final local$artwork = _instance.artwork;
    return local$artwork == null
        ? CopyWith$Fragment$ArtworkFragment.stub(_then(_instance))
        : CopyWith$Fragment$ArtworkFragment(
            local$artwork,
            (e) => call(artwork: e),
          );
  }
}

class _CopyWithStubImpl$Query$HomeScreen$recentlyAdded<TRes>
    implements CopyWith$Query$HomeScreen$recentlyAdded<TRes> {
  _CopyWithStubImpl$Query$HomeScreen$recentlyAdded(this._res);

  TRes _res;

  call({
    String? id,
    Enum$MediaType? type,
    String? title,
    int? year,
    Fragment$ArtworkFragment? artwork,
    String? addedAt,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork =>
      CopyWith$Fragment$ArtworkFragment.stub(_res);
}

class Query$HomeScreen$upNext {
  Query$HomeScreen$upNext({
    required this.progressState,
    required this.episode,
    required this.$show,
    this.$__typename = 'UpNextItem',
  });

  factory Query$HomeScreen$upNext.fromJson(Map<String, dynamic> json) {
    final l$progressState = json['progressState'];
    final l$episode = json['episode'];
    final l$$show = json['show'];
    final l$$__typename = json['__typename'];
    return Query$HomeScreen$upNext(
      progressState: (l$progressState as String),
      episode: Query$HomeScreen$upNext$episode.fromJson(
        (l$episode as Map<String, dynamic>),
      ),
      $show: Query$HomeScreen$upNext$show.fromJson(
        (l$$show as Map<String, dynamic>),
      ),
      $__typename: (l$$__typename as String),
    );
  }

  final String progressState;

  final Query$HomeScreen$upNext$episode episode;

  final Query$HomeScreen$upNext$show $show;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$progressState = progressState;
    _resultData['progressState'] = l$progressState;
    final l$episode = episode;
    _resultData['episode'] = l$episode.toJson();
    final l$$show = $show;
    _resultData['show'] = l$$show.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$progressState = progressState;
    final l$episode = episode;
    final l$$show = $show;
    final l$$__typename = $__typename;
    return Object.hashAll([l$progressState, l$episode, l$$show, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$HomeScreen$upNext || runtimeType != other.runtimeType) {
      return false;
    }
    final l$progressState = progressState;
    final lOther$progressState = other.progressState;
    if (l$progressState != lOther$progressState) {
      return false;
    }
    final l$episode = episode;
    final lOther$episode = other.episode;
    if (l$episode != lOther$episode) {
      return false;
    }
    final l$$show = $show;
    final lOther$$show = other.$show;
    if (l$$show != lOther$$show) {
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

extension UtilityExtension$Query$HomeScreen$upNext on Query$HomeScreen$upNext {
  CopyWith$Query$HomeScreen$upNext<Query$HomeScreen$upNext> get copyWith =>
      CopyWith$Query$HomeScreen$upNext(this, (i) => i);
}

abstract class CopyWith$Query$HomeScreen$upNext<TRes> {
  factory CopyWith$Query$HomeScreen$upNext(
    Query$HomeScreen$upNext instance,
    TRes Function(Query$HomeScreen$upNext) then,
  ) = _CopyWithImpl$Query$HomeScreen$upNext;

  factory CopyWith$Query$HomeScreen$upNext.stub(TRes res) =
      _CopyWithStubImpl$Query$HomeScreen$upNext;

  TRes call({
    String? progressState,
    Query$HomeScreen$upNext$episode? episode,
    Query$HomeScreen$upNext$show? $show,
    String? $__typename,
  });
  CopyWith$Query$HomeScreen$upNext$episode<TRes> get episode;
  CopyWith$Query$HomeScreen$upNext$show<TRes> get $show;
}

class _CopyWithImpl$Query$HomeScreen$upNext<TRes>
    implements CopyWith$Query$HomeScreen$upNext<TRes> {
  _CopyWithImpl$Query$HomeScreen$upNext(this._instance, this._then);

  final Query$HomeScreen$upNext _instance;

  final TRes Function(Query$HomeScreen$upNext) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? progressState = _undefined,
    Object? episode = _undefined,
    Object? $show = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$HomeScreen$upNext(
          progressState: progressState == _undefined || progressState == null
              ? _instance.progressState
              : (progressState as String),
          episode: episode == _undefined || episode == null
              ? _instance.episode
              : (episode as Query$HomeScreen$upNext$episode),
          $show: $show == _undefined || $show == null
              ? _instance.$show
              : ($show as Query$HomeScreen$upNext$show),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Query$HomeScreen$upNext$episode<TRes> get episode {
    final local$episode = _instance.episode;
    return CopyWith$Query$HomeScreen$upNext$episode(
      local$episode,
      (e) => call(episode: e),
    );
  }

  CopyWith$Query$HomeScreen$upNext$show<TRes> get $show {
    final local$$show = _instance.$show;
    return CopyWith$Query$HomeScreen$upNext$show(
      local$$show,
      (e) => call($show: e),
    );
  }
}

class _CopyWithStubImpl$Query$HomeScreen$upNext<TRes>
    implements CopyWith$Query$HomeScreen$upNext<TRes> {
  _CopyWithStubImpl$Query$HomeScreen$upNext(this._res);

  TRes _res;

  call({
    String? progressState,
    Query$HomeScreen$upNext$episode? episode,
    Query$HomeScreen$upNext$show? $show,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Query$HomeScreen$upNext$episode<TRes> get episode =>
      CopyWith$Query$HomeScreen$upNext$episode.stub(_res);

  CopyWith$Query$HomeScreen$upNext$show<TRes> get $show =>
      CopyWith$Query$HomeScreen$upNext$show.stub(_res);
}

class Query$HomeScreen$upNext$episode {
  Query$HomeScreen$upNext$episode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    this.title,
    this.airDate,
    this.thumbnailUrl,
    required this.hasFile,
    this.$__typename = 'Episode',
  });

  factory Query$HomeScreen$upNext$episode.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$seasonNumber = json['seasonNumber'];
    final l$episodeNumber = json['episodeNumber'];
    final l$title = json['title'];
    final l$airDate = json['airDate'];
    final l$thumbnailUrl = json['thumbnailUrl'];
    final l$hasFile = json['hasFile'];
    final l$$__typename = json['__typename'];
    return Query$HomeScreen$upNext$episode(
      id: (l$id as String),
      seasonNumber: (l$seasonNumber as int),
      episodeNumber: (l$episodeNumber as int),
      title: (l$title as String?),
      airDate: (l$airDate as String?),
      thumbnailUrl: (l$thumbnailUrl as String?),
      hasFile: (l$hasFile as bool),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final int seasonNumber;

  final int episodeNumber;

  final String? title;

  final String? airDate;

  final String? thumbnailUrl;

  final bool hasFile;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$seasonNumber = seasonNumber;
    _resultData['seasonNumber'] = l$seasonNumber;
    final l$episodeNumber = episodeNumber;
    _resultData['episodeNumber'] = l$episodeNumber;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$airDate = airDate;
    _resultData['airDate'] = l$airDate;
    final l$thumbnailUrl = thumbnailUrl;
    _resultData['thumbnailUrl'] = l$thumbnailUrl;
    final l$hasFile = hasFile;
    _resultData['hasFile'] = l$hasFile;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$seasonNumber = seasonNumber;
    final l$episodeNumber = episodeNumber;
    final l$title = title;
    final l$airDate = airDate;
    final l$thumbnailUrl = thumbnailUrl;
    final l$hasFile = hasFile;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$seasonNumber,
      l$episodeNumber,
      l$title,
      l$airDate,
      l$thumbnailUrl,
      l$hasFile,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$HomeScreen$upNext$episode ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$seasonNumber = seasonNumber;
    final lOther$seasonNumber = other.seasonNumber;
    if (l$seasonNumber != lOther$seasonNumber) {
      return false;
    }
    final l$episodeNumber = episodeNumber;
    final lOther$episodeNumber = other.episodeNumber;
    if (l$episodeNumber != lOther$episodeNumber) {
      return false;
    }
    final l$title = title;
    final lOther$title = other.title;
    if (l$title != lOther$title) {
      return false;
    }
    final l$airDate = airDate;
    final lOther$airDate = other.airDate;
    if (l$airDate != lOther$airDate) {
      return false;
    }
    final l$thumbnailUrl = thumbnailUrl;
    final lOther$thumbnailUrl = other.thumbnailUrl;
    if (l$thumbnailUrl != lOther$thumbnailUrl) {
      return false;
    }
    final l$hasFile = hasFile;
    final lOther$hasFile = other.hasFile;
    if (l$hasFile != lOther$hasFile) {
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

extension UtilityExtension$Query$HomeScreen$upNext$episode
    on Query$HomeScreen$upNext$episode {
  CopyWith$Query$HomeScreen$upNext$episode<Query$HomeScreen$upNext$episode>
      get copyWith => CopyWith$Query$HomeScreen$upNext$episode(this, (i) => i);
}

abstract class CopyWith$Query$HomeScreen$upNext$episode<TRes> {
  factory CopyWith$Query$HomeScreen$upNext$episode(
    Query$HomeScreen$upNext$episode instance,
    TRes Function(Query$HomeScreen$upNext$episode) then,
  ) = _CopyWithImpl$Query$HomeScreen$upNext$episode;

  factory CopyWith$Query$HomeScreen$upNext$episode.stub(TRes res) =
      _CopyWithStubImpl$Query$HomeScreen$upNext$episode;

  TRes call({
    String? id,
    int? seasonNumber,
    int? episodeNumber,
    String? title,
    String? airDate,
    String? thumbnailUrl,
    bool? hasFile,
    String? $__typename,
  });
}

class _CopyWithImpl$Query$HomeScreen$upNext$episode<TRes>
    implements CopyWith$Query$HomeScreen$upNext$episode<TRes> {
  _CopyWithImpl$Query$HomeScreen$upNext$episode(this._instance, this._then);

  final Query$HomeScreen$upNext$episode _instance;

  final TRes Function(Query$HomeScreen$upNext$episode) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? seasonNumber = _undefined,
    Object? episodeNumber = _undefined,
    Object? title = _undefined,
    Object? airDate = _undefined,
    Object? thumbnailUrl = _undefined,
    Object? hasFile = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$HomeScreen$upNext$episode(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          seasonNumber: seasonNumber == _undefined || seasonNumber == null
              ? _instance.seasonNumber
              : (seasonNumber as int),
          episodeNumber: episodeNumber == _undefined || episodeNumber == null
              ? _instance.episodeNumber
              : (episodeNumber as int),
          title: title == _undefined ? _instance.title : (title as String?),
          airDate:
              airDate == _undefined ? _instance.airDate : (airDate as String?),
          thumbnailUrl: thumbnailUrl == _undefined
              ? _instance.thumbnailUrl
              : (thumbnailUrl as String?),
          hasFile: hasFile == _undefined || hasFile == null
              ? _instance.hasFile
              : (hasFile as bool),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Query$HomeScreen$upNext$episode<TRes>
    implements CopyWith$Query$HomeScreen$upNext$episode<TRes> {
  _CopyWithStubImpl$Query$HomeScreen$upNext$episode(this._res);

  TRes _res;

  call({
    String? id,
    int? seasonNumber,
    int? episodeNumber,
    String? title,
    String? airDate,
    String? thumbnailUrl,
    bool? hasFile,
    String? $__typename,
  }) =>
      _res;
}

class Query$HomeScreen$upNext$show {
  Query$HomeScreen$upNext$show({
    required this.id,
    required this.title,
    this.artwork,
    this.$__typename = 'TvShow',
  });

  factory Query$HomeScreen$upNext$show.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$title = json['title'];
    final l$artwork = json['artwork'];
    final l$$__typename = json['__typename'];
    return Query$HomeScreen$upNext$show(
      id: (l$id as String),
      title: (l$title as String),
      artwork: l$artwork == null
          ? null
          : Fragment$ArtworkFragment.fromJson(
              (l$artwork as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String title;

  final Fragment$ArtworkFragment? artwork;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$artwork = artwork;
    _resultData['artwork'] = l$artwork?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$title = title;
    final l$artwork = artwork;
    final l$$__typename = $__typename;
    return Object.hashAll([l$id, l$title, l$artwork, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$HomeScreen$upNext$show ||
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
    final l$artwork = artwork;
    final lOther$artwork = other.artwork;
    if (l$artwork != lOther$artwork) {
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

extension UtilityExtension$Query$HomeScreen$upNext$show
    on Query$HomeScreen$upNext$show {
  CopyWith$Query$HomeScreen$upNext$show<Query$HomeScreen$upNext$show>
      get copyWith => CopyWith$Query$HomeScreen$upNext$show(this, (i) => i);
}

abstract class CopyWith$Query$HomeScreen$upNext$show<TRes> {
  factory CopyWith$Query$HomeScreen$upNext$show(
    Query$HomeScreen$upNext$show instance,
    TRes Function(Query$HomeScreen$upNext$show) then,
  ) = _CopyWithImpl$Query$HomeScreen$upNext$show;

  factory CopyWith$Query$HomeScreen$upNext$show.stub(TRes res) =
      _CopyWithStubImpl$Query$HomeScreen$upNext$show;

  TRes call({
    String? id,
    String? title,
    Fragment$ArtworkFragment? artwork,
    String? $__typename,
  });
  CopyWith$Fragment$ArtworkFragment<TRes> get artwork;
}

class _CopyWithImpl$Query$HomeScreen$upNext$show<TRes>
    implements CopyWith$Query$HomeScreen$upNext$show<TRes> {
  _CopyWithImpl$Query$HomeScreen$upNext$show(this._instance, this._then);

  final Query$HomeScreen$upNext$show _instance;

  final TRes Function(Query$HomeScreen$upNext$show) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? title = _undefined,
    Object? artwork = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$HomeScreen$upNext$show(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          title: title == _undefined || title == null
              ? _instance.title
              : (title as String),
          artwork: artwork == _undefined
              ? _instance.artwork
              : (artwork as Fragment$ArtworkFragment?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork {
    final local$artwork = _instance.artwork;
    return local$artwork == null
        ? CopyWith$Fragment$ArtworkFragment.stub(_then(_instance))
        : CopyWith$Fragment$ArtworkFragment(
            local$artwork,
            (e) => call(artwork: e),
          );
  }
}

class _CopyWithStubImpl$Query$HomeScreen$upNext$show<TRes>
    implements CopyWith$Query$HomeScreen$upNext$show<TRes> {
  _CopyWithStubImpl$Query$HomeScreen$upNext$show(this._res);

  TRes _res;

  call({
    String? id,
    String? title,
    Fragment$ArtworkFragment? artwork,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork =>
      CopyWith$Fragment$ArtworkFragment.stub(_res);
}

class Query$HomeScreen$trending {
  Query$HomeScreen$trending({
    required this.id,
    required this.type,
    required this.title,
    this.year,
    this.artwork,
    this.$__typename = 'SearchResult',
  });

  factory Query$HomeScreen$trending.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$type = json['type'];
    final l$title = json['title'];
    final l$year = json['year'];
    final l$artwork = json['artwork'];
    final l$$__typename = json['__typename'];
    return Query$HomeScreen$trending(
      id: (l$id as String),
      type: fromJson$Enum$MediaType((l$type as String)),
      title: (l$title as String),
      year: (l$year as int?),
      artwork: l$artwork == null
          ? null
          : Fragment$ArtworkFragment.fromJson(
              (l$artwork as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final Enum$MediaType type;

  final String title;

  final int? year;

  final Fragment$ArtworkFragment? artwork;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$type = type;
    _resultData['type'] = toJson$Enum$MediaType(l$type);
    final l$title = title;
    _resultData['title'] = l$title;
    final l$year = year;
    _resultData['year'] = l$year;
    final l$artwork = artwork;
    _resultData['artwork'] = l$artwork?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$type = type;
    final l$title = title;
    final l$year = year;
    final l$artwork = artwork;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$type,
      l$title,
      l$year,
      l$artwork,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$HomeScreen$trending ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$type = type;
    final lOther$type = other.type;
    if (l$type != lOther$type) {
      return false;
    }
    final l$title = title;
    final lOther$title = other.title;
    if (l$title != lOther$title) {
      return false;
    }
    final l$year = year;
    final lOther$year = other.year;
    if (l$year != lOther$year) {
      return false;
    }
    final l$artwork = artwork;
    final lOther$artwork = other.artwork;
    if (l$artwork != lOther$artwork) {
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

extension UtilityExtension$Query$HomeScreen$trending
    on Query$HomeScreen$trending {
  CopyWith$Query$HomeScreen$trending<Query$HomeScreen$trending> get copyWith =>
      CopyWith$Query$HomeScreen$trending(this, (i) => i);
}

abstract class CopyWith$Query$HomeScreen$trending<TRes> {
  factory CopyWith$Query$HomeScreen$trending(
    Query$HomeScreen$trending instance,
    TRes Function(Query$HomeScreen$trending) then,
  ) = _CopyWithImpl$Query$HomeScreen$trending;

  factory CopyWith$Query$HomeScreen$trending.stub(TRes res) =
      _CopyWithStubImpl$Query$HomeScreen$trending;

  TRes call({
    String? id,
    Enum$MediaType? type,
    String? title,
    int? year,
    Fragment$ArtworkFragment? artwork,
    String? $__typename,
  });
  CopyWith$Fragment$ArtworkFragment<TRes> get artwork;
}

class _CopyWithImpl$Query$HomeScreen$trending<TRes>
    implements CopyWith$Query$HomeScreen$trending<TRes> {
  _CopyWithImpl$Query$HomeScreen$trending(this._instance, this._then);

  final Query$HomeScreen$trending _instance;

  final TRes Function(Query$HomeScreen$trending) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? type = _undefined,
    Object? title = _undefined,
    Object? year = _undefined,
    Object? artwork = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$HomeScreen$trending(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          type: type == _undefined || type == null
              ? _instance.type
              : (type as Enum$MediaType),
          title: title == _undefined || title == null
              ? _instance.title
              : (title as String),
          year: year == _undefined ? _instance.year : (year as int?),
          artwork: artwork == _undefined
              ? _instance.artwork
              : (artwork as Fragment$ArtworkFragment?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork {
    final local$artwork = _instance.artwork;
    return local$artwork == null
        ? CopyWith$Fragment$ArtworkFragment.stub(_then(_instance))
        : CopyWith$Fragment$ArtworkFragment(
            local$artwork,
            (e) => call(artwork: e),
          );
  }
}

class _CopyWithStubImpl$Query$HomeScreen$trending<TRes>
    implements CopyWith$Query$HomeScreen$trending<TRes> {
  _CopyWithStubImpl$Query$HomeScreen$trending(this._res);

  TRes _res;

  call({
    String? id,
    Enum$MediaType? type,
    String? title,
    int? year,
    Fragment$ArtworkFragment? artwork,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork =>
      CopyWith$Fragment$ArtworkFragment.stub(_res);
}
