import '../fragments/artwork_fragment.graphql.dart';
import '../schema.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Query$TvShowsList {
  factory Variables$Query$TvShowsList({
    int? first,
    String? after,
    Enum$MediaCategory? category,
  }) =>
      Variables$Query$TvShowsList._({
        if (first != null) r'first': first,
        if (after != null) r'after': after,
        if (category != null) r'category': category,
      });

  Variables$Query$TvShowsList._(this._$data);

  factory Variables$Query$TvShowsList.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    if (data.containsKey('first')) {
      final l$first = data['first'];
      result$data['first'] = (l$first as int?);
    }
    if (data.containsKey('after')) {
      final l$after = data['after'];
      result$data['after'] = (l$after as String?);
    }
    if (data.containsKey('category')) {
      final l$category = data['category'];
      result$data['category'] = l$category == null
          ? null
          : fromJson$Enum$MediaCategory((l$category as String));
    }
    return Variables$Query$TvShowsList._(result$data);
  }

  Map<String, dynamic> _$data;

  int? get first => (_$data['first'] as int?);

  String? get after => (_$data['after'] as String?);

  Enum$MediaCategory? get category =>
      (_$data['category'] as Enum$MediaCategory?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    if (_$data.containsKey('first')) {
      final l$first = first;
      result$data['first'] = l$first;
    }
    if (_$data.containsKey('after')) {
      final l$after = after;
      result$data['after'] = l$after;
    }
    if (_$data.containsKey('category')) {
      final l$category = category;
      result$data['category'] =
          l$category == null ? null : toJson$Enum$MediaCategory(l$category);
    }
    return result$data;
  }

  CopyWith$Variables$Query$TvShowsList<Variables$Query$TvShowsList>
      get copyWith => CopyWith$Variables$Query$TvShowsList(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Query$TvShowsList ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$first = first;
    final lOther$first = other.first;
    if (_$data.containsKey('first') != other._$data.containsKey('first')) {
      return false;
    }
    if (l$first != lOther$first) {
      return false;
    }
    final l$after = after;
    final lOther$after = other.after;
    if (_$data.containsKey('after') != other._$data.containsKey('after')) {
      return false;
    }
    if (l$after != lOther$after) {
      return false;
    }
    final l$category = category;
    final lOther$category = other.category;
    if (_$data.containsKey('category') !=
        other._$data.containsKey('category')) {
      return false;
    }
    if (l$category != lOther$category) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$first = first;
    final l$after = after;
    final l$category = category;
    return Object.hashAll([
      _$data.containsKey('first') ? l$first : const {},
      _$data.containsKey('after') ? l$after : const {},
      _$data.containsKey('category') ? l$category : const {},
    ]);
  }
}

abstract class CopyWith$Variables$Query$TvShowsList<TRes> {
  factory CopyWith$Variables$Query$TvShowsList(
    Variables$Query$TvShowsList instance,
    TRes Function(Variables$Query$TvShowsList) then,
  ) = _CopyWithImpl$Variables$Query$TvShowsList;

  factory CopyWith$Variables$Query$TvShowsList.stub(TRes res) =
      _CopyWithStubImpl$Variables$Query$TvShowsList;

  TRes call({int? first, String? after, Enum$MediaCategory? category});
}

class _CopyWithImpl$Variables$Query$TvShowsList<TRes>
    implements CopyWith$Variables$Query$TvShowsList<TRes> {
  _CopyWithImpl$Variables$Query$TvShowsList(this._instance, this._then);

  final Variables$Query$TvShowsList _instance;

  final TRes Function(Variables$Query$TvShowsList) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? first = _undefined,
    Object? after = _undefined,
    Object? category = _undefined,
  }) =>
      _then(
        Variables$Query$TvShowsList._({
          ..._instance._$data,
          if (first != _undefined) 'first': (first as int?),
          if (after != _undefined) 'after': (after as String?),
          if (category != _undefined)
            'category': (category as Enum$MediaCategory?),
        }),
      );
}

class _CopyWithStubImpl$Variables$Query$TvShowsList<TRes>
    implements CopyWith$Variables$Query$TvShowsList<TRes> {
  _CopyWithStubImpl$Variables$Query$TvShowsList(this._res);

  TRes _res;

  call({int? first, String? after, Enum$MediaCategory? category}) => _res;
}

class Query$TvShowsList {
  Query$TvShowsList({this.tvShows, this.$__typename = 'RootQueryType'});

  factory Query$TvShowsList.fromJson(Map<String, dynamic> json) {
    final l$tvShows = json['tvShows'];
    final l$$__typename = json['__typename'];
    return Query$TvShowsList(
      tvShows: l$tvShows == null
          ? null
          : Query$TvShowsList$tvShows.fromJson(
              (l$tvShows as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Query$TvShowsList$tvShows? tvShows;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$tvShows = tvShows;
    _resultData['tvShows'] = l$tvShows?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$tvShows = tvShows;
    final l$$__typename = $__typename;
    return Object.hashAll([l$tvShows, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$TvShowsList || runtimeType != other.runtimeType) {
      return false;
    }
    final l$tvShows = tvShows;
    final lOther$tvShows = other.tvShows;
    if (l$tvShows != lOther$tvShows) {
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

extension UtilityExtension$Query$TvShowsList on Query$TvShowsList {
  CopyWith$Query$TvShowsList<Query$TvShowsList> get copyWith =>
      CopyWith$Query$TvShowsList(this, (i) => i);
}

abstract class CopyWith$Query$TvShowsList<TRes> {
  factory CopyWith$Query$TvShowsList(
    Query$TvShowsList instance,
    TRes Function(Query$TvShowsList) then,
  ) = _CopyWithImpl$Query$TvShowsList;

  factory CopyWith$Query$TvShowsList.stub(TRes res) =
      _CopyWithStubImpl$Query$TvShowsList;

  TRes call({Query$TvShowsList$tvShows? tvShows, String? $__typename});
  CopyWith$Query$TvShowsList$tvShows<TRes> get tvShows;
}

class _CopyWithImpl$Query$TvShowsList<TRes>
    implements CopyWith$Query$TvShowsList<TRes> {
  _CopyWithImpl$Query$TvShowsList(this._instance, this._then);

  final Query$TvShowsList _instance;

  final TRes Function(Query$TvShowsList) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? tvShows = _undefined, Object? $__typename = _undefined}) =>
      _then(
        Query$TvShowsList(
          tvShows: tvShows == _undefined
              ? _instance.tvShows
              : (tvShows as Query$TvShowsList$tvShows?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Query$TvShowsList$tvShows<TRes> get tvShows {
    final local$tvShows = _instance.tvShows;
    return local$tvShows == null
        ? CopyWith$Query$TvShowsList$tvShows.stub(_then(_instance))
        : CopyWith$Query$TvShowsList$tvShows(
            local$tvShows,
            (e) => call(tvShows: e),
          );
  }
}

class _CopyWithStubImpl$Query$TvShowsList<TRes>
    implements CopyWith$Query$TvShowsList<TRes> {
  _CopyWithStubImpl$Query$TvShowsList(this._res);

  TRes _res;

  call({Query$TvShowsList$tvShows? tvShows, String? $__typename}) => _res;

  CopyWith$Query$TvShowsList$tvShows<TRes> get tvShows =>
      CopyWith$Query$TvShowsList$tvShows.stub(_res);
}

const documentNodeQueryTvShowsList = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.query,
      name: NameNode(value: 'TvShowsList'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'first')),
          type: NamedTypeNode(name: NameNode(value: 'Int'), isNonNull: false),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'after')),
          type: NamedTypeNode(
            name: NameNode(value: 'String'),
            isNonNull: false,
          ),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'category')),
          type: NamedTypeNode(
            name: NameNode(value: 'MediaCategory'),
            isNonNull: false,
          ),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'tvShows'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'first'),
                value: VariableNode(name: NameNode(value: 'first')),
              ),
              ArgumentNode(
                name: NameNode(value: 'after'),
                value: VariableNode(name: NameNode(value: 'after')),
              ),
              ArgumentNode(
                name: NameNode(value: 'category'),
                value: VariableNode(name: NameNode(value: 'category')),
              ),
            ],
            directives: [],
            selectionSet: SelectionSetNode(
              selections: [
                FieldNode(
                  name: NameNode(value: 'edges'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: SelectionSetNode(
                    selections: [
                      FieldNode(
                        name: NameNode(value: 'node'),
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
                              name: NameNode(value: 'year'),
                              alias: null,
                              arguments: [],
                              directives: [],
                              selectionSet: null,
                            ),
                            FieldNode(
                              name: NameNode(value: 'overview'),
                              alias: null,
                              arguments: [],
                              directives: [],
                              selectionSet: null,
                            ),
                            FieldNode(
                              name: NameNode(value: 'status'),
                              alias: null,
                              arguments: [],
                              directives: [],
                              selectionSet: null,
                            ),
                            FieldNode(
                              name: NameNode(value: 'genres'),
                              alias: null,
                              arguments: [],
                              directives: [],
                              selectionSet: null,
                            ),
                            FieldNode(
                              name: NameNode(value: 'contentRating'),
                              alias: null,
                              arguments: [],
                              directives: [],
                              selectionSet: null,
                            ),
                            FieldNode(
                              name: NameNode(value: 'rating'),
                              alias: null,
                              arguments: [],
                              directives: [],
                              selectionSet: null,
                            ),
                            FieldNode(
                              name: NameNode(value: 'seasonCount'),
                              alias: null,
                              arguments: [],
                              directives: [],
                              selectionSet: null,
                            ),
                            FieldNode(
                              name: NameNode(value: 'episodeCount'),
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
                              name: NameNode(value: 'isFavorite'),
                              alias: null,
                              arguments: [],
                              directives: [],
                              selectionSet: null,
                            ),
                            FieldNode(
                              name: NameNode(value: 'nextEpisode'),
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
                        name: NameNode(value: 'cursor'),
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
                  name: NameNode(value: 'pageInfo'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: SelectionSetNode(
                    selections: [
                      FieldNode(
                        name: NameNode(value: 'hasNextPage'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'hasPreviousPage'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'startCursor'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'endCursor'),
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
                  name: NameNode(value: 'totalCount'),
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
    fragmentDefinitionArtworkFragment,
  ],
);

class Query$TvShowsList$tvShows {
  Query$TvShowsList$tvShows({
    required this.edges,
    required this.pageInfo,
    required this.totalCount,
    this.$__typename = 'TvShowConnection',
  });

  factory Query$TvShowsList$tvShows.fromJson(Map<String, dynamic> json) {
    final l$edges = json['edges'];
    final l$pageInfo = json['pageInfo'];
    final l$totalCount = json['totalCount'];
    final l$$__typename = json['__typename'];
    return Query$TvShowsList$tvShows(
      edges: (l$edges as List<dynamic>)
          .map(
            (e) => Query$TvShowsList$tvShows$edges.fromJson(
              (e as Map<String, dynamic>),
            ),
          )
          .toList(),
      pageInfo: Query$TvShowsList$tvShows$pageInfo.fromJson(
        (l$pageInfo as Map<String, dynamic>),
      ),
      totalCount: (l$totalCount as int),
      $__typename: (l$$__typename as String),
    );
  }

  final List<Query$TvShowsList$tvShows$edges> edges;

  final Query$TvShowsList$tvShows$pageInfo pageInfo;

  final int totalCount;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$edges = edges;
    _resultData['edges'] = l$edges.map((e) => e.toJson()).toList();
    final l$pageInfo = pageInfo;
    _resultData['pageInfo'] = l$pageInfo.toJson();
    final l$totalCount = totalCount;
    _resultData['totalCount'] = l$totalCount;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$edges = edges;
    final l$pageInfo = pageInfo;
    final l$totalCount = totalCount;
    final l$$__typename = $__typename;
    return Object.hashAll([
      Object.hashAll(l$edges.map((v) => v)),
      l$pageInfo,
      l$totalCount,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$TvShowsList$tvShows ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$edges = edges;
    final lOther$edges = other.edges;
    if (l$edges.length != lOther$edges.length) {
      return false;
    }
    for (int i = 0; i < l$edges.length; i++) {
      final l$edges$entry = l$edges[i];
      final lOther$edges$entry = lOther$edges[i];
      if (l$edges$entry != lOther$edges$entry) {
        return false;
      }
    }
    final l$pageInfo = pageInfo;
    final lOther$pageInfo = other.pageInfo;
    if (l$pageInfo != lOther$pageInfo) {
      return false;
    }
    final l$totalCount = totalCount;
    final lOther$totalCount = other.totalCount;
    if (l$totalCount != lOther$totalCount) {
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

extension UtilityExtension$Query$TvShowsList$tvShows
    on Query$TvShowsList$tvShows {
  CopyWith$Query$TvShowsList$tvShows<Query$TvShowsList$tvShows> get copyWith =>
      CopyWith$Query$TvShowsList$tvShows(this, (i) => i);
}

abstract class CopyWith$Query$TvShowsList$tvShows<TRes> {
  factory CopyWith$Query$TvShowsList$tvShows(
    Query$TvShowsList$tvShows instance,
    TRes Function(Query$TvShowsList$tvShows) then,
  ) = _CopyWithImpl$Query$TvShowsList$tvShows;

  factory CopyWith$Query$TvShowsList$tvShows.stub(TRes res) =
      _CopyWithStubImpl$Query$TvShowsList$tvShows;

  TRes call({
    List<Query$TvShowsList$tvShows$edges>? edges,
    Query$TvShowsList$tvShows$pageInfo? pageInfo,
    int? totalCount,
    String? $__typename,
  });
  TRes edges(
    Iterable<Query$TvShowsList$tvShows$edges> Function(
      Iterable<
          CopyWith$Query$TvShowsList$tvShows$edges<
              Query$TvShowsList$tvShows$edges>>,
    ) _fn,
  );
  CopyWith$Query$TvShowsList$tvShows$pageInfo<TRes> get pageInfo;
}

class _CopyWithImpl$Query$TvShowsList$tvShows<TRes>
    implements CopyWith$Query$TvShowsList$tvShows<TRes> {
  _CopyWithImpl$Query$TvShowsList$tvShows(this._instance, this._then);

  final Query$TvShowsList$tvShows _instance;

  final TRes Function(Query$TvShowsList$tvShows) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? edges = _undefined,
    Object? pageInfo = _undefined,
    Object? totalCount = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$TvShowsList$tvShows(
          edges: edges == _undefined || edges == null
              ? _instance.edges
              : (edges as List<Query$TvShowsList$tvShows$edges>),
          pageInfo: pageInfo == _undefined || pageInfo == null
              ? _instance.pageInfo
              : (pageInfo as Query$TvShowsList$tvShows$pageInfo),
          totalCount: totalCount == _undefined || totalCount == null
              ? _instance.totalCount
              : (totalCount as int),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  TRes edges(
    Iterable<Query$TvShowsList$tvShows$edges> Function(
      Iterable<
          CopyWith$Query$TvShowsList$tvShows$edges<
              Query$TvShowsList$tvShows$edges>>,
    ) _fn,
  ) =>
      call(
        edges: _fn(
          _instance.edges.map(
            (e) => CopyWith$Query$TvShowsList$tvShows$edges(e, (i) => i),
          ),
        ).toList(),
      );

  CopyWith$Query$TvShowsList$tvShows$pageInfo<TRes> get pageInfo {
    final local$pageInfo = _instance.pageInfo;
    return CopyWith$Query$TvShowsList$tvShows$pageInfo(
      local$pageInfo,
      (e) => call(pageInfo: e),
    );
  }
}

class _CopyWithStubImpl$Query$TvShowsList$tvShows<TRes>
    implements CopyWith$Query$TvShowsList$tvShows<TRes> {
  _CopyWithStubImpl$Query$TvShowsList$tvShows(this._res);

  TRes _res;

  call({
    List<Query$TvShowsList$tvShows$edges>? edges,
    Query$TvShowsList$tvShows$pageInfo? pageInfo,
    int? totalCount,
    String? $__typename,
  }) =>
      _res;

  edges(_fn) => _res;

  CopyWith$Query$TvShowsList$tvShows$pageInfo<TRes> get pageInfo =>
      CopyWith$Query$TvShowsList$tvShows$pageInfo.stub(_res);
}

class Query$TvShowsList$tvShows$edges {
  Query$TvShowsList$tvShows$edges({
    required this.node,
    required this.cursor,
    this.$__typename = 'TvShowEdge',
  });

  factory Query$TvShowsList$tvShows$edges.fromJson(Map<String, dynamic> json) {
    final l$node = json['node'];
    final l$cursor = json['cursor'];
    final l$$__typename = json['__typename'];
    return Query$TvShowsList$tvShows$edges(
      node: Query$TvShowsList$tvShows$edges$node.fromJson(
        (l$node as Map<String, dynamic>),
      ),
      cursor: (l$cursor as String),
      $__typename: (l$$__typename as String),
    );
  }

  final Query$TvShowsList$tvShows$edges$node node;

  final String cursor;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$node = node;
    _resultData['node'] = l$node.toJson();
    final l$cursor = cursor;
    _resultData['cursor'] = l$cursor;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$node = node;
    final l$cursor = cursor;
    final l$$__typename = $__typename;
    return Object.hashAll([l$node, l$cursor, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$TvShowsList$tvShows$edges ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$node = node;
    final lOther$node = other.node;
    if (l$node != lOther$node) {
      return false;
    }
    final l$cursor = cursor;
    final lOther$cursor = other.cursor;
    if (l$cursor != lOther$cursor) {
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

extension UtilityExtension$Query$TvShowsList$tvShows$edges
    on Query$TvShowsList$tvShows$edges {
  CopyWith$Query$TvShowsList$tvShows$edges<Query$TvShowsList$tvShows$edges>
      get copyWith => CopyWith$Query$TvShowsList$tvShows$edges(this, (i) => i);
}

abstract class CopyWith$Query$TvShowsList$tvShows$edges<TRes> {
  factory CopyWith$Query$TvShowsList$tvShows$edges(
    Query$TvShowsList$tvShows$edges instance,
    TRes Function(Query$TvShowsList$tvShows$edges) then,
  ) = _CopyWithImpl$Query$TvShowsList$tvShows$edges;

  factory CopyWith$Query$TvShowsList$tvShows$edges.stub(TRes res) =
      _CopyWithStubImpl$Query$TvShowsList$tvShows$edges;

  TRes call({
    Query$TvShowsList$tvShows$edges$node? node,
    String? cursor,
    String? $__typename,
  });
  CopyWith$Query$TvShowsList$tvShows$edges$node<TRes> get node;
}

class _CopyWithImpl$Query$TvShowsList$tvShows$edges<TRes>
    implements CopyWith$Query$TvShowsList$tvShows$edges<TRes> {
  _CopyWithImpl$Query$TvShowsList$tvShows$edges(this._instance, this._then);

  final Query$TvShowsList$tvShows$edges _instance;

  final TRes Function(Query$TvShowsList$tvShows$edges) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? node = _undefined,
    Object? cursor = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$TvShowsList$tvShows$edges(
          node: node == _undefined || node == null
              ? _instance.node
              : (node as Query$TvShowsList$tvShows$edges$node),
          cursor: cursor == _undefined || cursor == null
              ? _instance.cursor
              : (cursor as String),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Query$TvShowsList$tvShows$edges$node<TRes> get node {
    final local$node = _instance.node;
    return CopyWith$Query$TvShowsList$tvShows$edges$node(
      local$node,
      (e) => call(node: e),
    );
  }
}

class _CopyWithStubImpl$Query$TvShowsList$tvShows$edges<TRes>
    implements CopyWith$Query$TvShowsList$tvShows$edges<TRes> {
  _CopyWithStubImpl$Query$TvShowsList$tvShows$edges(this._res);

  TRes _res;

  call({
    Query$TvShowsList$tvShows$edges$node? node,
    String? cursor,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Query$TvShowsList$tvShows$edges$node<TRes> get node =>
      CopyWith$Query$TvShowsList$tvShows$edges$node.stub(_res);
}

class Query$TvShowsList$tvShows$edges$node {
  Query$TvShowsList$tvShows$edges$node({
    required this.id,
    required this.title,
    this.year,
    this.overview,
    this.status,
    this.genres,
    this.contentRating,
    this.rating,
    this.seasonCount,
    this.episodeCount,
    this.artwork,
    required this.isFavorite,
    this.nextEpisode,
    this.$__typename = 'TvShow',
  });

  factory Query$TvShowsList$tvShows$edges$node.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$title = json['title'];
    final l$year = json['year'];
    final l$overview = json['overview'];
    final l$status = json['status'];
    final l$genres = json['genres'];
    final l$contentRating = json['contentRating'];
    final l$rating = json['rating'];
    final l$seasonCount = json['seasonCount'];
    final l$episodeCount = json['episodeCount'];
    final l$artwork = json['artwork'];
    final l$isFavorite = json['isFavorite'];
    final l$nextEpisode = json['nextEpisode'];
    final l$$__typename = json['__typename'];
    return Query$TvShowsList$tvShows$edges$node(
      id: (l$id as String),
      title: (l$title as String),
      year: (l$year as int?),
      overview: (l$overview as String?),
      status: (l$status as String?),
      genres: (l$genres as List<dynamic>?)?.map((e) => (e as String?)).toList(),
      contentRating: (l$contentRating as String?),
      rating: (l$rating as num?)?.toDouble(),
      seasonCount: (l$seasonCount as int?),
      episodeCount: (l$episodeCount as int?),
      artwork: l$artwork == null
          ? null
          : Fragment$ArtworkFragment.fromJson(
              (l$artwork as Map<String, dynamic>),
            ),
      isFavorite: (l$isFavorite as bool),
      nextEpisode: l$nextEpisode == null
          ? null
          : Query$TvShowsList$tvShows$edges$node$nextEpisode.fromJson(
              (l$nextEpisode as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String title;

  final int? year;

  final String? overview;

  final String? status;

  final List<String?>? genres;

  final String? contentRating;

  final double? rating;

  final int? seasonCount;

  final int? episodeCount;

  final Fragment$ArtworkFragment? artwork;

  final bool isFavorite;

  final Query$TvShowsList$tvShows$edges$node$nextEpisode? nextEpisode;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$title = title;
    _resultData['title'] = l$title;
    final l$year = year;
    _resultData['year'] = l$year;
    final l$overview = overview;
    _resultData['overview'] = l$overview;
    final l$status = status;
    _resultData['status'] = l$status;
    final l$genres = genres;
    _resultData['genres'] = l$genres?.map((e) => e).toList();
    final l$contentRating = contentRating;
    _resultData['contentRating'] = l$contentRating;
    final l$rating = rating;
    _resultData['rating'] = l$rating;
    final l$seasonCount = seasonCount;
    _resultData['seasonCount'] = l$seasonCount;
    final l$episodeCount = episodeCount;
    _resultData['episodeCount'] = l$episodeCount;
    final l$artwork = artwork;
    _resultData['artwork'] = l$artwork?.toJson();
    final l$isFavorite = isFavorite;
    _resultData['isFavorite'] = l$isFavorite;
    final l$nextEpisode = nextEpisode;
    _resultData['nextEpisode'] = l$nextEpisode?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$title = title;
    final l$year = year;
    final l$overview = overview;
    final l$status = status;
    final l$genres = genres;
    final l$contentRating = contentRating;
    final l$rating = rating;
    final l$seasonCount = seasonCount;
    final l$episodeCount = episodeCount;
    final l$artwork = artwork;
    final l$isFavorite = isFavorite;
    final l$nextEpisode = nextEpisode;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$title,
      l$year,
      l$overview,
      l$status,
      l$genres == null ? null : Object.hashAll(l$genres.map((v) => v)),
      l$contentRating,
      l$rating,
      l$seasonCount,
      l$episodeCount,
      l$artwork,
      l$isFavorite,
      l$nextEpisode,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$TvShowsList$tvShows$edges$node ||
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
    final l$year = year;
    final lOther$year = other.year;
    if (l$year != lOther$year) {
      return false;
    }
    final l$overview = overview;
    final lOther$overview = other.overview;
    if (l$overview != lOther$overview) {
      return false;
    }
    final l$status = status;
    final lOther$status = other.status;
    if (l$status != lOther$status) {
      return false;
    }
    final l$genres = genres;
    final lOther$genres = other.genres;
    if (l$genres != null && lOther$genres != null) {
      if (l$genres.length != lOther$genres.length) {
        return false;
      }
      for (int i = 0; i < l$genres.length; i++) {
        final l$genres$entry = l$genres[i];
        final lOther$genres$entry = lOther$genres[i];
        if (l$genres$entry != lOther$genres$entry) {
          return false;
        }
      }
    } else if (l$genres != lOther$genres) {
      return false;
    }
    final l$contentRating = contentRating;
    final lOther$contentRating = other.contentRating;
    if (l$contentRating != lOther$contentRating) {
      return false;
    }
    final l$rating = rating;
    final lOther$rating = other.rating;
    if (l$rating != lOther$rating) {
      return false;
    }
    final l$seasonCount = seasonCount;
    final lOther$seasonCount = other.seasonCount;
    if (l$seasonCount != lOther$seasonCount) {
      return false;
    }
    final l$episodeCount = episodeCount;
    final lOther$episodeCount = other.episodeCount;
    if (l$episodeCount != lOther$episodeCount) {
      return false;
    }
    final l$artwork = artwork;
    final lOther$artwork = other.artwork;
    if (l$artwork != lOther$artwork) {
      return false;
    }
    final l$isFavorite = isFavorite;
    final lOther$isFavorite = other.isFavorite;
    if (l$isFavorite != lOther$isFavorite) {
      return false;
    }
    final l$nextEpisode = nextEpisode;
    final lOther$nextEpisode = other.nextEpisode;
    if (l$nextEpisode != lOther$nextEpisode) {
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

extension UtilityExtension$Query$TvShowsList$tvShows$edges$node
    on Query$TvShowsList$tvShows$edges$node {
  CopyWith$Query$TvShowsList$tvShows$edges$node<
          Query$TvShowsList$tvShows$edges$node>
      get copyWith =>
          CopyWith$Query$TvShowsList$tvShows$edges$node(this, (i) => i);
}

abstract class CopyWith$Query$TvShowsList$tvShows$edges$node<TRes> {
  factory CopyWith$Query$TvShowsList$tvShows$edges$node(
    Query$TvShowsList$tvShows$edges$node instance,
    TRes Function(Query$TvShowsList$tvShows$edges$node) then,
  ) = _CopyWithImpl$Query$TvShowsList$tvShows$edges$node;

  factory CopyWith$Query$TvShowsList$tvShows$edges$node.stub(TRes res) =
      _CopyWithStubImpl$Query$TvShowsList$tvShows$edges$node;

  TRes call({
    String? id,
    String? title,
    int? year,
    String? overview,
    String? status,
    List<String?>? genres,
    String? contentRating,
    double? rating,
    int? seasonCount,
    int? episodeCount,
    Fragment$ArtworkFragment? artwork,
    bool? isFavorite,
    Query$TvShowsList$tvShows$edges$node$nextEpisode? nextEpisode,
    String? $__typename,
  });
  CopyWith$Fragment$ArtworkFragment<TRes> get artwork;
  CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode<TRes>
      get nextEpisode;
}

class _CopyWithImpl$Query$TvShowsList$tvShows$edges$node<TRes>
    implements CopyWith$Query$TvShowsList$tvShows$edges$node<TRes> {
  _CopyWithImpl$Query$TvShowsList$tvShows$edges$node(
    this._instance,
    this._then,
  );

  final Query$TvShowsList$tvShows$edges$node _instance;

  final TRes Function(Query$TvShowsList$tvShows$edges$node) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? title = _undefined,
    Object? year = _undefined,
    Object? overview = _undefined,
    Object? status = _undefined,
    Object? genres = _undefined,
    Object? contentRating = _undefined,
    Object? rating = _undefined,
    Object? seasonCount = _undefined,
    Object? episodeCount = _undefined,
    Object? artwork = _undefined,
    Object? isFavorite = _undefined,
    Object? nextEpisode = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$TvShowsList$tvShows$edges$node(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          title: title == _undefined || title == null
              ? _instance.title
              : (title as String),
          year: year == _undefined ? _instance.year : (year as int?),
          overview: overview == _undefined
              ? _instance.overview
              : (overview as String?),
          status: status == _undefined ? _instance.status : (status as String?),
          genres: genres == _undefined
              ? _instance.genres
              : (genres as List<String?>?),
          contentRating: contentRating == _undefined
              ? _instance.contentRating
              : (contentRating as String?),
          rating: rating == _undefined ? _instance.rating : (rating as double?),
          seasonCount: seasonCount == _undefined
              ? _instance.seasonCount
              : (seasonCount as int?),
          episodeCount: episodeCount == _undefined
              ? _instance.episodeCount
              : (episodeCount as int?),
          artwork: artwork == _undefined
              ? _instance.artwork
              : (artwork as Fragment$ArtworkFragment?),
          isFavorite: isFavorite == _undefined || isFavorite == null
              ? _instance.isFavorite
              : (isFavorite as bool),
          nextEpisode: nextEpisode == _undefined
              ? _instance.nextEpisode
              : (nextEpisode
                  as Query$TvShowsList$tvShows$edges$node$nextEpisode?),
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

  CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode<TRes>
      get nextEpisode {
    final local$nextEpisode = _instance.nextEpisode;
    return local$nextEpisode == null
        ? CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode.stub(
            _then(_instance),
          )
        : CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode(
            local$nextEpisode,
            (e) => call(nextEpisode: e),
          );
  }
}

class _CopyWithStubImpl$Query$TvShowsList$tvShows$edges$node<TRes>
    implements CopyWith$Query$TvShowsList$tvShows$edges$node<TRes> {
  _CopyWithStubImpl$Query$TvShowsList$tvShows$edges$node(this._res);

  TRes _res;

  call({
    String? id,
    String? title,
    int? year,
    String? overview,
    String? status,
    List<String?>? genres,
    String? contentRating,
    double? rating,
    int? seasonCount,
    int? episodeCount,
    Fragment$ArtworkFragment? artwork,
    bool? isFavorite,
    Query$TvShowsList$tvShows$edges$node$nextEpisode? nextEpisode,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork =>
      CopyWith$Fragment$ArtworkFragment.stub(_res);

  CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode<TRes>
      get nextEpisode =>
          CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode.stub(_res);
}

class Query$TvShowsList$tvShows$edges$node$nextEpisode {
  Query$TvShowsList$tvShows$edges$node$nextEpisode({
    required this.id,
    required this.seasonNumber,
    required this.episodeNumber,
    this.title,
    this.$__typename = 'Episode',
  });

  factory Query$TvShowsList$tvShows$edges$node$nextEpisode.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$seasonNumber = json['seasonNumber'];
    final l$episodeNumber = json['episodeNumber'];
    final l$title = json['title'];
    final l$$__typename = json['__typename'];
    return Query$TvShowsList$tvShows$edges$node$nextEpisode(
      id: (l$id as String),
      seasonNumber: (l$seasonNumber as int),
      episodeNumber: (l$episodeNumber as int),
      title: (l$title as String?),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final int seasonNumber;

  final int episodeNumber;

  final String? title;

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
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$seasonNumber,
      l$episodeNumber,
      l$title,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$TvShowsList$tvShows$edges$node$nextEpisode ||
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
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$TvShowsList$tvShows$edges$node$nextEpisode
    on Query$TvShowsList$tvShows$edges$node$nextEpisode {
  CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode<
          Query$TvShowsList$tvShows$edges$node$nextEpisode>
      get copyWith => CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode(
          this, (i) => i);
}

abstract class CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode<TRes> {
  factory CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode(
    Query$TvShowsList$tvShows$edges$node$nextEpisode instance,
    TRes Function(Query$TvShowsList$tvShows$edges$node$nextEpisode) then,
  ) = _CopyWithImpl$Query$TvShowsList$tvShows$edges$node$nextEpisode;

  factory CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode.stub(
    TRes res,
  ) = _CopyWithStubImpl$Query$TvShowsList$tvShows$edges$node$nextEpisode;

  TRes call({
    String? id,
    int? seasonNumber,
    int? episodeNumber,
    String? title,
    String? $__typename,
  });
}

class _CopyWithImpl$Query$TvShowsList$tvShows$edges$node$nextEpisode<TRes>
    implements CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode<TRes> {
  _CopyWithImpl$Query$TvShowsList$tvShows$edges$node$nextEpisode(
    this._instance,
    this._then,
  );

  final Query$TvShowsList$tvShows$edges$node$nextEpisode _instance;

  final TRes Function(Query$TvShowsList$tvShows$edges$node$nextEpisode) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? seasonNumber = _undefined,
    Object? episodeNumber = _undefined,
    Object? title = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$TvShowsList$tvShows$edges$node$nextEpisode(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          seasonNumber: seasonNumber == _undefined || seasonNumber == null
              ? _instance.seasonNumber
              : (seasonNumber as int),
          episodeNumber: episodeNumber == _undefined || episodeNumber == null
              ? _instance.episodeNumber
              : (episodeNumber as int),
          title: title == _undefined ? _instance.title : (title as String?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Query$TvShowsList$tvShows$edges$node$nextEpisode<TRes>
    implements CopyWith$Query$TvShowsList$tvShows$edges$node$nextEpisode<TRes> {
  _CopyWithStubImpl$Query$TvShowsList$tvShows$edges$node$nextEpisode(this._res);

  TRes _res;

  call({
    String? id,
    int? seasonNumber,
    int? episodeNumber,
    String? title,
    String? $__typename,
  }) =>
      _res;
}

class Query$TvShowsList$tvShows$pageInfo {
  Query$TvShowsList$tvShows$pageInfo({
    required this.hasNextPage,
    required this.hasPreviousPage,
    this.startCursor,
    this.endCursor,
    this.$__typename = 'PageInfo',
  });

  factory Query$TvShowsList$tvShows$pageInfo.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$hasNextPage = json['hasNextPage'];
    final l$hasPreviousPage = json['hasPreviousPage'];
    final l$startCursor = json['startCursor'];
    final l$endCursor = json['endCursor'];
    final l$$__typename = json['__typename'];
    return Query$TvShowsList$tvShows$pageInfo(
      hasNextPage: (l$hasNextPage as bool),
      hasPreviousPage: (l$hasPreviousPage as bool),
      startCursor: (l$startCursor as String?),
      endCursor: (l$endCursor as String?),
      $__typename: (l$$__typename as String),
    );
  }

  final bool hasNextPage;

  final bool hasPreviousPage;

  final String? startCursor;

  final String? endCursor;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$hasNextPage = hasNextPage;
    _resultData['hasNextPage'] = l$hasNextPage;
    final l$hasPreviousPage = hasPreviousPage;
    _resultData['hasPreviousPage'] = l$hasPreviousPage;
    final l$startCursor = startCursor;
    _resultData['startCursor'] = l$startCursor;
    final l$endCursor = endCursor;
    _resultData['endCursor'] = l$endCursor;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$hasNextPage = hasNextPage;
    final l$hasPreviousPage = hasPreviousPage;
    final l$startCursor = startCursor;
    final l$endCursor = endCursor;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$hasNextPage,
      l$hasPreviousPage,
      l$startCursor,
      l$endCursor,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$TvShowsList$tvShows$pageInfo ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$hasNextPage = hasNextPage;
    final lOther$hasNextPage = other.hasNextPage;
    if (l$hasNextPage != lOther$hasNextPage) {
      return false;
    }
    final l$hasPreviousPage = hasPreviousPage;
    final lOther$hasPreviousPage = other.hasPreviousPage;
    if (l$hasPreviousPage != lOther$hasPreviousPage) {
      return false;
    }
    final l$startCursor = startCursor;
    final lOther$startCursor = other.startCursor;
    if (l$startCursor != lOther$startCursor) {
      return false;
    }
    final l$endCursor = endCursor;
    final lOther$endCursor = other.endCursor;
    if (l$endCursor != lOther$endCursor) {
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

extension UtilityExtension$Query$TvShowsList$tvShows$pageInfo
    on Query$TvShowsList$tvShows$pageInfo {
  CopyWith$Query$TvShowsList$tvShows$pageInfo<
          Query$TvShowsList$tvShows$pageInfo>
      get copyWith =>
          CopyWith$Query$TvShowsList$tvShows$pageInfo(this, (i) => i);
}

abstract class CopyWith$Query$TvShowsList$tvShows$pageInfo<TRes> {
  factory CopyWith$Query$TvShowsList$tvShows$pageInfo(
    Query$TvShowsList$tvShows$pageInfo instance,
    TRes Function(Query$TvShowsList$tvShows$pageInfo) then,
  ) = _CopyWithImpl$Query$TvShowsList$tvShows$pageInfo;

  factory CopyWith$Query$TvShowsList$tvShows$pageInfo.stub(TRes res) =
      _CopyWithStubImpl$Query$TvShowsList$tvShows$pageInfo;

  TRes call({
    bool? hasNextPage,
    bool? hasPreviousPage,
    String? startCursor,
    String? endCursor,
    String? $__typename,
  });
}

class _CopyWithImpl$Query$TvShowsList$tvShows$pageInfo<TRes>
    implements CopyWith$Query$TvShowsList$tvShows$pageInfo<TRes> {
  _CopyWithImpl$Query$TvShowsList$tvShows$pageInfo(this._instance, this._then);

  final Query$TvShowsList$tvShows$pageInfo _instance;

  final TRes Function(Query$TvShowsList$tvShows$pageInfo) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? hasNextPage = _undefined,
    Object? hasPreviousPage = _undefined,
    Object? startCursor = _undefined,
    Object? endCursor = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$TvShowsList$tvShows$pageInfo(
          hasNextPage: hasNextPage == _undefined || hasNextPage == null
              ? _instance.hasNextPage
              : (hasNextPage as bool),
          hasPreviousPage:
              hasPreviousPage == _undefined || hasPreviousPage == null
                  ? _instance.hasPreviousPage
                  : (hasPreviousPage as bool),
          startCursor: startCursor == _undefined
              ? _instance.startCursor
              : (startCursor as String?),
          endCursor: endCursor == _undefined
              ? _instance.endCursor
              : (endCursor as String?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Query$TvShowsList$tvShows$pageInfo<TRes>
    implements CopyWith$Query$TvShowsList$tvShows$pageInfo<TRes> {
  _CopyWithStubImpl$Query$TvShowsList$tvShows$pageInfo(this._res);

  TRes _res;

  call({
    bool? hasNextPage,
    bool? hasPreviousPage,
    String? startCursor,
    String? endCursor,
    String? $__typename,
  }) =>
      _res;
}
