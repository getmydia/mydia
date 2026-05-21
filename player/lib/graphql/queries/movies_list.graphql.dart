import '../fragments/artwork_fragment.graphql.dart';
import '../fragments/progress_fragment.graphql.dart';
import '../schema.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Query$MoviesList {
  factory Variables$Query$MoviesList({
    int? first,
    String? after,
    Enum$MediaCategory? category,
  }) =>
      Variables$Query$MoviesList._({
        if (first != null) r'first': first,
        if (after != null) r'after': after,
        if (category != null) r'category': category,
      });

  Variables$Query$MoviesList._(this._$data);

  factory Variables$Query$MoviesList.fromJson(Map<String, dynamic> data) {
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
    return Variables$Query$MoviesList._(result$data);
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

  CopyWith$Variables$Query$MoviesList<Variables$Query$MoviesList>
      get copyWith => CopyWith$Variables$Query$MoviesList(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Query$MoviesList ||
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

abstract class CopyWith$Variables$Query$MoviesList<TRes> {
  factory CopyWith$Variables$Query$MoviesList(
    Variables$Query$MoviesList instance,
    TRes Function(Variables$Query$MoviesList) then,
  ) = _CopyWithImpl$Variables$Query$MoviesList;

  factory CopyWith$Variables$Query$MoviesList.stub(TRes res) =
      _CopyWithStubImpl$Variables$Query$MoviesList;

  TRes call({int? first, String? after, Enum$MediaCategory? category});
}

class _CopyWithImpl$Variables$Query$MoviesList<TRes>
    implements CopyWith$Variables$Query$MoviesList<TRes> {
  _CopyWithImpl$Variables$Query$MoviesList(this._instance, this._then);

  final Variables$Query$MoviesList _instance;

  final TRes Function(Variables$Query$MoviesList) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? first = _undefined,
    Object? after = _undefined,
    Object? category = _undefined,
  }) =>
      _then(
        Variables$Query$MoviesList._({
          ..._instance._$data,
          if (first != _undefined) 'first': (first as int?),
          if (after != _undefined) 'after': (after as String?),
          if (category != _undefined)
            'category': (category as Enum$MediaCategory?),
        }),
      );
}

class _CopyWithStubImpl$Variables$Query$MoviesList<TRes>
    implements CopyWith$Variables$Query$MoviesList<TRes> {
  _CopyWithStubImpl$Variables$Query$MoviesList(this._res);

  TRes _res;

  call({int? first, String? after, Enum$MediaCategory? category}) => _res;
}

class Query$MoviesList {
  Query$MoviesList({this.movies, this.$__typename = 'RootQueryType'});

  factory Query$MoviesList.fromJson(Map<String, dynamic> json) {
    final l$movies = json['movies'];
    final l$$__typename = json['__typename'];
    return Query$MoviesList(
      movies: l$movies == null
          ? null
          : Query$MoviesList$movies.fromJson(
              (l$movies as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Query$MoviesList$movies? movies;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$movies = movies;
    _resultData['movies'] = l$movies?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$movies = movies;
    final l$$__typename = $__typename;
    return Object.hashAll([l$movies, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$MoviesList || runtimeType != other.runtimeType) {
      return false;
    }
    final l$movies = movies;
    final lOther$movies = other.movies;
    if (l$movies != lOther$movies) {
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

extension UtilityExtension$Query$MoviesList on Query$MoviesList {
  CopyWith$Query$MoviesList<Query$MoviesList> get copyWith =>
      CopyWith$Query$MoviesList(this, (i) => i);
}

abstract class CopyWith$Query$MoviesList<TRes> {
  factory CopyWith$Query$MoviesList(
    Query$MoviesList instance,
    TRes Function(Query$MoviesList) then,
  ) = _CopyWithImpl$Query$MoviesList;

  factory CopyWith$Query$MoviesList.stub(TRes res) =
      _CopyWithStubImpl$Query$MoviesList;

  TRes call({Query$MoviesList$movies? movies, String? $__typename});
  CopyWith$Query$MoviesList$movies<TRes> get movies;
}

class _CopyWithImpl$Query$MoviesList<TRes>
    implements CopyWith$Query$MoviesList<TRes> {
  _CopyWithImpl$Query$MoviesList(this._instance, this._then);

  final Query$MoviesList _instance;

  final TRes Function(Query$MoviesList) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? movies = _undefined, Object? $__typename = _undefined}) =>
      _then(
        Query$MoviesList(
          movies: movies == _undefined
              ? _instance.movies
              : (movies as Query$MoviesList$movies?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Query$MoviesList$movies<TRes> get movies {
    final local$movies = _instance.movies;
    return local$movies == null
        ? CopyWith$Query$MoviesList$movies.stub(_then(_instance))
        : CopyWith$Query$MoviesList$movies(
            local$movies,
            (e) => call(movies: e),
          );
  }
}

class _CopyWithStubImpl$Query$MoviesList<TRes>
    implements CopyWith$Query$MoviesList<TRes> {
  _CopyWithStubImpl$Query$MoviesList(this._res);

  TRes _res;

  call({Query$MoviesList$movies? movies, String? $__typename}) => _res;

  CopyWith$Query$MoviesList$movies<TRes> get movies =>
      CopyWith$Query$MoviesList$movies.stub(_res);
}

const documentNodeQueryMoviesList = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.query,
      name: NameNode(value: 'MoviesList'),
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
            name: NameNode(value: 'movies'),
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
                              name: NameNode(value: 'runtime'),
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
                              name: NameNode(value: 'isFavorite'),
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
    fragmentDefinitionProgressFragment,
  ],
);

class Query$MoviesList$movies {
  Query$MoviesList$movies({
    required this.edges,
    required this.pageInfo,
    required this.totalCount,
    this.$__typename = 'MovieConnection',
  });

  factory Query$MoviesList$movies.fromJson(Map<String, dynamic> json) {
    final l$edges = json['edges'];
    final l$pageInfo = json['pageInfo'];
    final l$totalCount = json['totalCount'];
    final l$$__typename = json['__typename'];
    return Query$MoviesList$movies(
      edges: (l$edges as List<dynamic>)
          .map(
            (e) => Query$MoviesList$movies$edges.fromJson(
              (e as Map<String, dynamic>),
            ),
          )
          .toList(),
      pageInfo: Query$MoviesList$movies$pageInfo.fromJson(
        (l$pageInfo as Map<String, dynamic>),
      ),
      totalCount: (l$totalCount as int),
      $__typename: (l$$__typename as String),
    );
  }

  final List<Query$MoviesList$movies$edges> edges;

  final Query$MoviesList$movies$pageInfo pageInfo;

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
    if (other is! Query$MoviesList$movies || runtimeType != other.runtimeType) {
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

extension UtilityExtension$Query$MoviesList$movies on Query$MoviesList$movies {
  CopyWith$Query$MoviesList$movies<Query$MoviesList$movies> get copyWith =>
      CopyWith$Query$MoviesList$movies(this, (i) => i);
}

abstract class CopyWith$Query$MoviesList$movies<TRes> {
  factory CopyWith$Query$MoviesList$movies(
    Query$MoviesList$movies instance,
    TRes Function(Query$MoviesList$movies) then,
  ) = _CopyWithImpl$Query$MoviesList$movies;

  factory CopyWith$Query$MoviesList$movies.stub(TRes res) =
      _CopyWithStubImpl$Query$MoviesList$movies;

  TRes call({
    List<Query$MoviesList$movies$edges>? edges,
    Query$MoviesList$movies$pageInfo? pageInfo,
    int? totalCount,
    String? $__typename,
  });
  TRes edges(
    Iterable<Query$MoviesList$movies$edges> Function(
      Iterable<
          CopyWith$Query$MoviesList$movies$edges<
              Query$MoviesList$movies$edges>>,
    ) _fn,
  );
  CopyWith$Query$MoviesList$movies$pageInfo<TRes> get pageInfo;
}

class _CopyWithImpl$Query$MoviesList$movies<TRes>
    implements CopyWith$Query$MoviesList$movies<TRes> {
  _CopyWithImpl$Query$MoviesList$movies(this._instance, this._then);

  final Query$MoviesList$movies _instance;

  final TRes Function(Query$MoviesList$movies) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? edges = _undefined,
    Object? pageInfo = _undefined,
    Object? totalCount = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$MoviesList$movies(
          edges: edges == _undefined || edges == null
              ? _instance.edges
              : (edges as List<Query$MoviesList$movies$edges>),
          pageInfo: pageInfo == _undefined || pageInfo == null
              ? _instance.pageInfo
              : (pageInfo as Query$MoviesList$movies$pageInfo),
          totalCount: totalCount == _undefined || totalCount == null
              ? _instance.totalCount
              : (totalCount as int),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  TRes edges(
    Iterable<Query$MoviesList$movies$edges> Function(
      Iterable<
          CopyWith$Query$MoviesList$movies$edges<
              Query$MoviesList$movies$edges>>,
    ) _fn,
  ) =>
      call(
        edges: _fn(
          _instance.edges.map(
            (e) => CopyWith$Query$MoviesList$movies$edges(e, (i) => i),
          ),
        ).toList(),
      );

  CopyWith$Query$MoviesList$movies$pageInfo<TRes> get pageInfo {
    final local$pageInfo = _instance.pageInfo;
    return CopyWith$Query$MoviesList$movies$pageInfo(
      local$pageInfo,
      (e) => call(pageInfo: e),
    );
  }
}

class _CopyWithStubImpl$Query$MoviesList$movies<TRes>
    implements CopyWith$Query$MoviesList$movies<TRes> {
  _CopyWithStubImpl$Query$MoviesList$movies(this._res);

  TRes _res;

  call({
    List<Query$MoviesList$movies$edges>? edges,
    Query$MoviesList$movies$pageInfo? pageInfo,
    int? totalCount,
    String? $__typename,
  }) =>
      _res;

  edges(_fn) => _res;

  CopyWith$Query$MoviesList$movies$pageInfo<TRes> get pageInfo =>
      CopyWith$Query$MoviesList$movies$pageInfo.stub(_res);
}

class Query$MoviesList$movies$edges {
  Query$MoviesList$movies$edges({
    required this.node,
    required this.cursor,
    this.$__typename = 'MovieEdge',
  });

  factory Query$MoviesList$movies$edges.fromJson(Map<String, dynamic> json) {
    final l$node = json['node'];
    final l$cursor = json['cursor'];
    final l$$__typename = json['__typename'];
    return Query$MoviesList$movies$edges(
      node: Query$MoviesList$movies$edges$node.fromJson(
        (l$node as Map<String, dynamic>),
      ),
      cursor: (l$cursor as String),
      $__typename: (l$$__typename as String),
    );
  }

  final Query$MoviesList$movies$edges$node node;

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
    if (other is! Query$MoviesList$movies$edges ||
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

extension UtilityExtension$Query$MoviesList$movies$edges
    on Query$MoviesList$movies$edges {
  CopyWith$Query$MoviesList$movies$edges<Query$MoviesList$movies$edges>
      get copyWith => CopyWith$Query$MoviesList$movies$edges(this, (i) => i);
}

abstract class CopyWith$Query$MoviesList$movies$edges<TRes> {
  factory CopyWith$Query$MoviesList$movies$edges(
    Query$MoviesList$movies$edges instance,
    TRes Function(Query$MoviesList$movies$edges) then,
  ) = _CopyWithImpl$Query$MoviesList$movies$edges;

  factory CopyWith$Query$MoviesList$movies$edges.stub(TRes res) =
      _CopyWithStubImpl$Query$MoviesList$movies$edges;

  TRes call({
    Query$MoviesList$movies$edges$node? node,
    String? cursor,
    String? $__typename,
  });
  CopyWith$Query$MoviesList$movies$edges$node<TRes> get node;
}

class _CopyWithImpl$Query$MoviesList$movies$edges<TRes>
    implements CopyWith$Query$MoviesList$movies$edges<TRes> {
  _CopyWithImpl$Query$MoviesList$movies$edges(this._instance, this._then);

  final Query$MoviesList$movies$edges _instance;

  final TRes Function(Query$MoviesList$movies$edges) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? node = _undefined,
    Object? cursor = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$MoviesList$movies$edges(
          node: node == _undefined || node == null
              ? _instance.node
              : (node as Query$MoviesList$movies$edges$node),
          cursor: cursor == _undefined || cursor == null
              ? _instance.cursor
              : (cursor as String),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Query$MoviesList$movies$edges$node<TRes> get node {
    final local$node = _instance.node;
    return CopyWith$Query$MoviesList$movies$edges$node(
      local$node,
      (e) => call(node: e),
    );
  }
}

class _CopyWithStubImpl$Query$MoviesList$movies$edges<TRes>
    implements CopyWith$Query$MoviesList$movies$edges<TRes> {
  _CopyWithStubImpl$Query$MoviesList$movies$edges(this._res);

  TRes _res;

  call({
    Query$MoviesList$movies$edges$node? node,
    String? cursor,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Query$MoviesList$movies$edges$node<TRes> get node =>
      CopyWith$Query$MoviesList$movies$edges$node.stub(_res);
}

class Query$MoviesList$movies$edges$node {
  Query$MoviesList$movies$edges$node({
    required this.id,
    required this.title,
    this.year,
    this.overview,
    this.runtime,
    this.genres,
    this.contentRating,
    this.rating,
    this.artwork,
    this.progress,
    required this.isFavorite,
    this.$__typename = 'Movie',
  });

  factory Query$MoviesList$movies$edges$node.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$title = json['title'];
    final l$year = json['year'];
    final l$overview = json['overview'];
    final l$runtime = json['runtime'];
    final l$genres = json['genres'];
    final l$contentRating = json['contentRating'];
    final l$rating = json['rating'];
    final l$artwork = json['artwork'];
    final l$progress = json['progress'];
    final l$isFavorite = json['isFavorite'];
    final l$$__typename = json['__typename'];
    return Query$MoviesList$movies$edges$node(
      id: (l$id as String),
      title: (l$title as String),
      year: (l$year as int?),
      overview: (l$overview as String?),
      runtime: (l$runtime as int?),
      genres: (l$genres as List<dynamic>?)?.map((e) => (e as String?)).toList(),
      contentRating: (l$contentRating as String?),
      rating: (l$rating as num?)?.toDouble(),
      artwork: l$artwork == null
          ? null
          : Fragment$ArtworkFragment.fromJson(
              (l$artwork as Map<String, dynamic>),
            ),
      progress: l$progress == null
          ? null
          : Fragment$ProgressFragment.fromJson(
              (l$progress as Map<String, dynamic>),
            ),
      isFavorite: (l$isFavorite as bool),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String title;

  final int? year;

  final String? overview;

  final int? runtime;

  final List<String?>? genres;

  final String? contentRating;

  final double? rating;

  final Fragment$ArtworkFragment? artwork;

  final Fragment$ProgressFragment? progress;

  final bool isFavorite;

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
    final l$runtime = runtime;
    _resultData['runtime'] = l$runtime;
    final l$genres = genres;
    _resultData['genres'] = l$genres?.map((e) => e).toList();
    final l$contentRating = contentRating;
    _resultData['contentRating'] = l$contentRating;
    final l$rating = rating;
    _resultData['rating'] = l$rating;
    final l$artwork = artwork;
    _resultData['artwork'] = l$artwork?.toJson();
    final l$progress = progress;
    _resultData['progress'] = l$progress?.toJson();
    final l$isFavorite = isFavorite;
    _resultData['isFavorite'] = l$isFavorite;
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
    final l$runtime = runtime;
    final l$genres = genres;
    final l$contentRating = contentRating;
    final l$rating = rating;
    final l$artwork = artwork;
    final l$progress = progress;
    final l$isFavorite = isFavorite;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$title,
      l$year,
      l$overview,
      l$runtime,
      l$genres == null ? null : Object.hashAll(l$genres.map((v) => v)),
      l$contentRating,
      l$rating,
      l$artwork,
      l$progress,
      l$isFavorite,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$MoviesList$movies$edges$node ||
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
    final l$runtime = runtime;
    final lOther$runtime = other.runtime;
    if (l$runtime != lOther$runtime) {
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
    final l$isFavorite = isFavorite;
    final lOther$isFavorite = other.isFavorite;
    if (l$isFavorite != lOther$isFavorite) {
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

extension UtilityExtension$Query$MoviesList$movies$edges$node
    on Query$MoviesList$movies$edges$node {
  CopyWith$Query$MoviesList$movies$edges$node<
          Query$MoviesList$movies$edges$node>
      get copyWith =>
          CopyWith$Query$MoviesList$movies$edges$node(this, (i) => i);
}

abstract class CopyWith$Query$MoviesList$movies$edges$node<TRes> {
  factory CopyWith$Query$MoviesList$movies$edges$node(
    Query$MoviesList$movies$edges$node instance,
    TRes Function(Query$MoviesList$movies$edges$node) then,
  ) = _CopyWithImpl$Query$MoviesList$movies$edges$node;

  factory CopyWith$Query$MoviesList$movies$edges$node.stub(TRes res) =
      _CopyWithStubImpl$Query$MoviesList$movies$edges$node;

  TRes call({
    String? id,
    String? title,
    int? year,
    String? overview,
    int? runtime,
    List<String?>? genres,
    String? contentRating,
    double? rating,
    Fragment$ArtworkFragment? artwork,
    Fragment$ProgressFragment? progress,
    bool? isFavorite,
    String? $__typename,
  });
  CopyWith$Fragment$ArtworkFragment<TRes> get artwork;
  CopyWith$Fragment$ProgressFragment<TRes> get progress;
}

class _CopyWithImpl$Query$MoviesList$movies$edges$node<TRes>
    implements CopyWith$Query$MoviesList$movies$edges$node<TRes> {
  _CopyWithImpl$Query$MoviesList$movies$edges$node(this._instance, this._then);

  final Query$MoviesList$movies$edges$node _instance;

  final TRes Function(Query$MoviesList$movies$edges$node) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? title = _undefined,
    Object? year = _undefined,
    Object? overview = _undefined,
    Object? runtime = _undefined,
    Object? genres = _undefined,
    Object? contentRating = _undefined,
    Object? rating = _undefined,
    Object? artwork = _undefined,
    Object? progress = _undefined,
    Object? isFavorite = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$MoviesList$movies$edges$node(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          title: title == _undefined || title == null
              ? _instance.title
              : (title as String),
          year: year == _undefined ? _instance.year : (year as int?),
          overview: overview == _undefined
              ? _instance.overview
              : (overview as String?),
          runtime:
              runtime == _undefined ? _instance.runtime : (runtime as int?),
          genres: genres == _undefined
              ? _instance.genres
              : (genres as List<String?>?),
          contentRating: contentRating == _undefined
              ? _instance.contentRating
              : (contentRating as String?),
          rating: rating == _undefined ? _instance.rating : (rating as double?),
          artwork: artwork == _undefined
              ? _instance.artwork
              : (artwork as Fragment$ArtworkFragment?),
          progress: progress == _undefined
              ? _instance.progress
              : (progress as Fragment$ProgressFragment?),
          isFavorite: isFavorite == _undefined || isFavorite == null
              ? _instance.isFavorite
              : (isFavorite as bool),
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
    return local$progress == null
        ? CopyWith$Fragment$ProgressFragment.stub(_then(_instance))
        : CopyWith$Fragment$ProgressFragment(
            local$progress,
            (e) => call(progress: e),
          );
  }
}

class _CopyWithStubImpl$Query$MoviesList$movies$edges$node<TRes>
    implements CopyWith$Query$MoviesList$movies$edges$node<TRes> {
  _CopyWithStubImpl$Query$MoviesList$movies$edges$node(this._res);

  TRes _res;

  call({
    String? id,
    String? title,
    int? year,
    String? overview,
    int? runtime,
    List<String?>? genres,
    String? contentRating,
    double? rating,
    Fragment$ArtworkFragment? artwork,
    Fragment$ProgressFragment? progress,
    bool? isFavorite,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork =>
      CopyWith$Fragment$ArtworkFragment.stub(_res);

  CopyWith$Fragment$ProgressFragment<TRes> get progress =>
      CopyWith$Fragment$ProgressFragment.stub(_res);
}

class Query$MoviesList$movies$pageInfo {
  Query$MoviesList$movies$pageInfo({
    required this.hasNextPage,
    required this.hasPreviousPage,
    this.startCursor,
    this.endCursor,
    this.$__typename = 'PageInfo',
  });

  factory Query$MoviesList$movies$pageInfo.fromJson(Map<String, dynamic> json) {
    final l$hasNextPage = json['hasNextPage'];
    final l$hasPreviousPage = json['hasPreviousPage'];
    final l$startCursor = json['startCursor'];
    final l$endCursor = json['endCursor'];
    final l$$__typename = json['__typename'];
    return Query$MoviesList$movies$pageInfo(
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
    if (other is! Query$MoviesList$movies$pageInfo ||
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

extension UtilityExtension$Query$MoviesList$movies$pageInfo
    on Query$MoviesList$movies$pageInfo {
  CopyWith$Query$MoviesList$movies$pageInfo<Query$MoviesList$movies$pageInfo>
      get copyWith => CopyWith$Query$MoviesList$movies$pageInfo(this, (i) => i);
}

abstract class CopyWith$Query$MoviesList$movies$pageInfo<TRes> {
  factory CopyWith$Query$MoviesList$movies$pageInfo(
    Query$MoviesList$movies$pageInfo instance,
    TRes Function(Query$MoviesList$movies$pageInfo) then,
  ) = _CopyWithImpl$Query$MoviesList$movies$pageInfo;

  factory CopyWith$Query$MoviesList$movies$pageInfo.stub(TRes res) =
      _CopyWithStubImpl$Query$MoviesList$movies$pageInfo;

  TRes call({
    bool? hasNextPage,
    bool? hasPreviousPage,
    String? startCursor,
    String? endCursor,
    String? $__typename,
  });
}

class _CopyWithImpl$Query$MoviesList$movies$pageInfo<TRes>
    implements CopyWith$Query$MoviesList$movies$pageInfo<TRes> {
  _CopyWithImpl$Query$MoviesList$movies$pageInfo(this._instance, this._then);

  final Query$MoviesList$movies$pageInfo _instance;

  final TRes Function(Query$MoviesList$movies$pageInfo) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? hasNextPage = _undefined,
    Object? hasPreviousPage = _undefined,
    Object? startCursor = _undefined,
    Object? endCursor = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$MoviesList$movies$pageInfo(
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

class _CopyWithStubImpl$Query$MoviesList$movies$pageInfo<TRes>
    implements CopyWith$Query$MoviesList$movies$pageInfo<TRes> {
  _CopyWithStubImpl$Query$MoviesList$movies$pageInfo(this._res);

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
