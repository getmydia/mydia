import '../fragments/artwork_fragment.graphql.dart';
import '../schema.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Query$Search {
  factory Variables$Query$Search({
    required String query,
    List<Enum$SearchResultType?>? types,
    int? first,
  }) =>
      Variables$Query$Search._({
        r'query': query,
        if (types != null) r'types': types,
        if (first != null) r'first': first,
      });

  Variables$Query$Search._(this._$data);

  factory Variables$Query$Search.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    final l$query = data['query'];
    result$data['query'] = (l$query as String);
    if (data.containsKey('types')) {
      final l$types = data['types'];
      result$data['types'] = (l$types as List<dynamic>?)
          ?.map(
            (e) => e == null
                ? null
                : fromJson$Enum$SearchResultType((e as String)),
          )
          .toList();
    }
    if (data.containsKey('first')) {
      final l$first = data['first'];
      result$data['first'] = (l$first as int?);
    }
    return Variables$Query$Search._(result$data);
  }

  Map<String, dynamic> _$data;

  String get query => (_$data['query'] as String);

  List<Enum$SearchResultType?>? get types =>
      (_$data['types'] as List<Enum$SearchResultType?>?);

  int? get first => (_$data['first'] as int?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$query = query;
    result$data['query'] = l$query;
    if (_$data.containsKey('types')) {
      final l$types = types;
      result$data['types'] = l$types
          ?.map((e) => e == null ? null : toJson$Enum$SearchResultType(e))
          .toList();
    }
    if (_$data.containsKey('first')) {
      final l$first = first;
      result$data['first'] = l$first;
    }
    return result$data;
  }

  CopyWith$Variables$Query$Search<Variables$Query$Search> get copyWith =>
      CopyWith$Variables$Query$Search(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Query$Search || runtimeType != other.runtimeType) {
      return false;
    }
    final l$query = query;
    final lOther$query = other.query;
    if (l$query != lOther$query) {
      return false;
    }
    final l$types = types;
    final lOther$types = other.types;
    if (_$data.containsKey('types') != other._$data.containsKey('types')) {
      return false;
    }
    if (l$types != null && lOther$types != null) {
      if (l$types.length != lOther$types.length) {
        return false;
      }
      for (int i = 0; i < l$types.length; i++) {
        final l$types$entry = l$types[i];
        final lOther$types$entry = lOther$types[i];
        if (l$types$entry != lOther$types$entry) {
          return false;
        }
      }
    } else if (l$types != lOther$types) {
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
    return true;
  }

  @override
  int get hashCode {
    final l$query = query;
    final l$types = types;
    final l$first = first;
    return Object.hashAll([
      l$query,
      _$data.containsKey('types')
          ? l$types == null
              ? null
              : Object.hashAll(l$types.map((v) => v))
          : const {},
      _$data.containsKey('first') ? l$first : const {},
    ]);
  }
}

abstract class CopyWith$Variables$Query$Search<TRes> {
  factory CopyWith$Variables$Query$Search(
    Variables$Query$Search instance,
    TRes Function(Variables$Query$Search) then,
  ) = _CopyWithImpl$Variables$Query$Search;

  factory CopyWith$Variables$Query$Search.stub(TRes res) =
      _CopyWithStubImpl$Variables$Query$Search;

  TRes call({String? query, List<Enum$SearchResultType?>? types, int? first});
}

class _CopyWithImpl$Variables$Query$Search<TRes>
    implements CopyWith$Variables$Query$Search<TRes> {
  _CopyWithImpl$Variables$Query$Search(this._instance, this._then);

  final Variables$Query$Search _instance;

  final TRes Function(Variables$Query$Search) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? query = _undefined,
    Object? types = _undefined,
    Object? first = _undefined,
  }) =>
      _then(
        Variables$Query$Search._({
          ..._instance._$data,
          if (query != _undefined && query != null) 'query': (query as String),
          if (types != _undefined)
            'types': (types as List<Enum$SearchResultType?>?),
          if (first != _undefined) 'first': (first as int?),
        }),
      );
}

class _CopyWithStubImpl$Variables$Query$Search<TRes>
    implements CopyWith$Variables$Query$Search<TRes> {
  _CopyWithStubImpl$Variables$Query$Search(this._res);

  TRes _res;

  call({String? query, List<Enum$SearchResultType?>? types, int? first}) =>
      _res;
}

class Query$Search {
  Query$Search({this.search, this.$__typename = 'RootQueryType'});

  factory Query$Search.fromJson(Map<String, dynamic> json) {
    final l$search = json['search'];
    final l$$__typename = json['__typename'];
    return Query$Search(
      search: l$search == null
          ? null
          : Query$Search$search.fromJson((l$search as Map<String, dynamic>)),
      $__typename: (l$$__typename as String),
    );
  }

  final Query$Search$search? search;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$search = search;
    _resultData['search'] = l$search?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$search = search;
    final l$$__typename = $__typename;
    return Object.hashAll([l$search, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$Search || runtimeType != other.runtimeType) {
      return false;
    }
    final l$search = search;
    final lOther$search = other.search;
    if (l$search != lOther$search) {
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

extension UtilityExtension$Query$Search on Query$Search {
  CopyWith$Query$Search<Query$Search> get copyWith =>
      CopyWith$Query$Search(this, (i) => i);
}

abstract class CopyWith$Query$Search<TRes> {
  factory CopyWith$Query$Search(
    Query$Search instance,
    TRes Function(Query$Search) then,
  ) = _CopyWithImpl$Query$Search;

  factory CopyWith$Query$Search.stub(TRes res) = _CopyWithStubImpl$Query$Search;

  TRes call({Query$Search$search? search, String? $__typename});
  CopyWith$Query$Search$search<TRes> get search;
}

class _CopyWithImpl$Query$Search<TRes> implements CopyWith$Query$Search<TRes> {
  _CopyWithImpl$Query$Search(this._instance, this._then);

  final Query$Search _instance;

  final TRes Function(Query$Search) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? search = _undefined, Object? $__typename = _undefined}) =>
      _then(
        Query$Search(
          search: search == _undefined
              ? _instance.search
              : (search as Query$Search$search?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Query$Search$search<TRes> get search {
    final local$search = _instance.search;
    return local$search == null
        ? CopyWith$Query$Search$search.stub(_then(_instance))
        : CopyWith$Query$Search$search(local$search, (e) => call(search: e));
  }
}

class _CopyWithStubImpl$Query$Search<TRes>
    implements CopyWith$Query$Search<TRes> {
  _CopyWithStubImpl$Query$Search(this._res);

  TRes _res;

  call({Query$Search$search? search, String? $__typename}) => _res;

  CopyWith$Query$Search$search<TRes> get search =>
      CopyWith$Query$Search$search.stub(_res);
}

const documentNodeQuerySearch = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.query,
      name: NameNode(value: 'Search'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'query')),
          type: NamedTypeNode(name: NameNode(value: 'String'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'types')),
          type: ListTypeNode(
            type: NamedTypeNode(
              name: NameNode(value: 'SearchResultType'),
              isNonNull: false,
            ),
            isNonNull: false,
          ),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'first')),
          type: NamedTypeNode(name: NameNode(value: 'Int'), isNonNull: false),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'search'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'query'),
                value: VariableNode(name: NameNode(value: 'query')),
              ),
              ArgumentNode(
                name: NameNode(value: 'types'),
                value: VariableNode(name: NameNode(value: 'types')),
              ),
              ArgumentNode(
                name: NameNode(value: 'first'),
                value: VariableNode(name: NameNode(value: 'first')),
              ),
            ],
            directives: [],
            selectionSet: SelectionSetNode(
              selections: [
                FieldNode(
                  name: NameNode(value: 'totalCount'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'sections'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: SelectionSetNode(
                    selections: [
                      FieldNode(
                        name: NameNode(value: 'type'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'totalCount'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'results'),
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
                              name: NameNode(value: 'subtitle'),
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
                              name: NameNode(value: 'parentId'),
                              alias: null,
                              arguments: [],
                              directives: [],
                              selectionSet: null,
                            ),
                            FieldNode(
                              name: NameNode(value: 'score'),
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

class Query$Search$search {
  Query$Search$search({
    required this.totalCount,
    required this.sections,
    this.$__typename = 'SearchResults',
  });

  factory Query$Search$search.fromJson(Map<String, dynamic> json) {
    final l$totalCount = json['totalCount'];
    final l$sections = json['sections'];
    final l$$__typename = json['__typename'];
    return Query$Search$search(
      totalCount: (l$totalCount as int),
      sections: (l$sections as List<dynamic>)
          .map(
            (e) => Query$Search$search$sections.fromJson(
              (e as Map<String, dynamic>),
            ),
          )
          .toList(),
      $__typename: (l$$__typename as String),
    );
  }

  final int totalCount;

  final List<Query$Search$search$sections> sections;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$totalCount = totalCount;
    _resultData['totalCount'] = l$totalCount;
    final l$sections = sections;
    _resultData['sections'] = l$sections.map((e) => e.toJson()).toList();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$totalCount = totalCount;
    final l$sections = sections;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$totalCount,
      Object.hashAll(l$sections.map((v) => v)),
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$Search$search || runtimeType != other.runtimeType) {
      return false;
    }
    final l$totalCount = totalCount;
    final lOther$totalCount = other.totalCount;
    if (l$totalCount != lOther$totalCount) {
      return false;
    }
    final l$sections = sections;
    final lOther$sections = other.sections;
    if (l$sections.length != lOther$sections.length) {
      return false;
    }
    for (int i = 0; i < l$sections.length; i++) {
      final l$sections$entry = l$sections[i];
      final lOther$sections$entry = lOther$sections[i];
      if (l$sections$entry != lOther$sections$entry) {
        return false;
      }
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$Search$search on Query$Search$search {
  CopyWith$Query$Search$search<Query$Search$search> get copyWith =>
      CopyWith$Query$Search$search(this, (i) => i);
}

abstract class CopyWith$Query$Search$search<TRes> {
  factory CopyWith$Query$Search$search(
    Query$Search$search instance,
    TRes Function(Query$Search$search) then,
  ) = _CopyWithImpl$Query$Search$search;

  factory CopyWith$Query$Search$search.stub(TRes res) =
      _CopyWithStubImpl$Query$Search$search;

  TRes call({
    int? totalCount,
    List<Query$Search$search$sections>? sections,
    String? $__typename,
  });
  TRes sections(
    Iterable<Query$Search$search$sections> Function(
      Iterable<
          CopyWith$Query$Search$search$sections<Query$Search$search$sections>>,
    ) _fn,
  );
}

class _CopyWithImpl$Query$Search$search<TRes>
    implements CopyWith$Query$Search$search<TRes> {
  _CopyWithImpl$Query$Search$search(this._instance, this._then);

  final Query$Search$search _instance;

  final TRes Function(Query$Search$search) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? totalCount = _undefined,
    Object? sections = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$Search$search(
          totalCount: totalCount == _undefined || totalCount == null
              ? _instance.totalCount
              : (totalCount as int),
          sections: sections == _undefined || sections == null
              ? _instance.sections
              : (sections as List<Query$Search$search$sections>),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  TRes sections(
    Iterable<Query$Search$search$sections> Function(
      Iterable<
          CopyWith$Query$Search$search$sections<Query$Search$search$sections>>,
    ) _fn,
  ) =>
      call(
        sections: _fn(
          _instance.sections.map(
            (e) => CopyWith$Query$Search$search$sections(e, (i) => i),
          ),
        ).toList(),
      );
}

class _CopyWithStubImpl$Query$Search$search<TRes>
    implements CopyWith$Query$Search$search<TRes> {
  _CopyWithStubImpl$Query$Search$search(this._res);

  TRes _res;

  call({
    int? totalCount,
    List<Query$Search$search$sections>? sections,
    String? $__typename,
  }) =>
      _res;

  sections(_fn) => _res;
}

class Query$Search$search$sections {
  Query$Search$search$sections({
    required this.type,
    required this.totalCount,
    required this.results,
    this.$__typename = 'SearchSection',
  });

  factory Query$Search$search$sections.fromJson(Map<String, dynamic> json) {
    final l$type = json['type'];
    final l$totalCount = json['totalCount'];
    final l$results = json['results'];
    final l$$__typename = json['__typename'];
    return Query$Search$search$sections(
      type: fromJson$Enum$SearchResultType((l$type as String)),
      totalCount: (l$totalCount as int),
      results: (l$results as List<dynamic>)
          .map(
            (e) => Query$Search$search$sections$results.fromJson(
              (e as Map<String, dynamic>),
            ),
          )
          .toList(),
      $__typename: (l$$__typename as String),
    );
  }

  final Enum$SearchResultType type;

  final int totalCount;

  final List<Query$Search$search$sections$results> results;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$type = type;
    _resultData['type'] = toJson$Enum$SearchResultType(l$type);
    final l$totalCount = totalCount;
    _resultData['totalCount'] = l$totalCount;
    final l$results = results;
    _resultData['results'] = l$results.map((e) => e.toJson()).toList();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$type = type;
    final l$totalCount = totalCount;
    final l$results = results;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$type,
      l$totalCount,
      Object.hashAll(l$results.map((v) => v)),
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$Search$search$sections ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$type = type;
    final lOther$type = other.type;
    if (l$type != lOther$type) {
      return false;
    }
    final l$totalCount = totalCount;
    final lOther$totalCount = other.totalCount;
    if (l$totalCount != lOther$totalCount) {
      return false;
    }
    final l$results = results;
    final lOther$results = other.results;
    if (l$results.length != lOther$results.length) {
      return false;
    }
    for (int i = 0; i < l$results.length; i++) {
      final l$results$entry = l$results[i];
      final lOther$results$entry = lOther$results[i];
      if (l$results$entry != lOther$results$entry) {
        return false;
      }
    }
    final l$$__typename = $__typename;
    final lOther$$__typename = other.$__typename;
    if (l$$__typename != lOther$$__typename) {
      return false;
    }
    return true;
  }
}

extension UtilityExtension$Query$Search$search$sections
    on Query$Search$search$sections {
  CopyWith$Query$Search$search$sections<Query$Search$search$sections>
      get copyWith => CopyWith$Query$Search$search$sections(this, (i) => i);
}

abstract class CopyWith$Query$Search$search$sections<TRes> {
  factory CopyWith$Query$Search$search$sections(
    Query$Search$search$sections instance,
    TRes Function(Query$Search$search$sections) then,
  ) = _CopyWithImpl$Query$Search$search$sections;

  factory CopyWith$Query$Search$search$sections.stub(TRes res) =
      _CopyWithStubImpl$Query$Search$search$sections;

  TRes call({
    Enum$SearchResultType? type,
    int? totalCount,
    List<Query$Search$search$sections$results>? results,
    String? $__typename,
  });
  TRes results(
    Iterable<Query$Search$search$sections$results> Function(
      Iterable<
          CopyWith$Query$Search$search$sections$results<
              Query$Search$search$sections$results>>,
    ) _fn,
  );
}

class _CopyWithImpl$Query$Search$search$sections<TRes>
    implements CopyWith$Query$Search$search$sections<TRes> {
  _CopyWithImpl$Query$Search$search$sections(this._instance, this._then);

  final Query$Search$search$sections _instance;

  final TRes Function(Query$Search$search$sections) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? type = _undefined,
    Object? totalCount = _undefined,
    Object? results = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$Search$search$sections(
          type: type == _undefined || type == null
              ? _instance.type
              : (type as Enum$SearchResultType),
          totalCount: totalCount == _undefined || totalCount == null
              ? _instance.totalCount
              : (totalCount as int),
          results: results == _undefined || results == null
              ? _instance.results
              : (results as List<Query$Search$search$sections$results>),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  TRes results(
    Iterable<Query$Search$search$sections$results> Function(
      Iterable<
          CopyWith$Query$Search$search$sections$results<
              Query$Search$search$sections$results>>,
    ) _fn,
  ) =>
      call(
        results: _fn(
          _instance.results.map(
            (e) => CopyWith$Query$Search$search$sections$results(e, (i) => i),
          ),
        ).toList(),
      );
}

class _CopyWithStubImpl$Query$Search$search$sections<TRes>
    implements CopyWith$Query$Search$search$sections<TRes> {
  _CopyWithStubImpl$Query$Search$search$sections(this._res);

  TRes _res;

  call({
    Enum$SearchResultType? type,
    int? totalCount,
    List<Query$Search$search$sections$results>? results,
    String? $__typename,
  }) =>
      _res;

  results(_fn) => _res;
}

class Query$Search$search$sections$results {
  Query$Search$search$sections$results({
    required this.id,
    required this.type,
    required this.title,
    this.year,
    this.subtitle,
    this.seasonNumber,
    this.episodeNumber,
    this.parentId,
    this.score,
    this.artwork,
    this.$__typename = 'SearchResult',
  });

  factory Query$Search$search$sections$results.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$type = json['type'];
    final l$title = json['title'];
    final l$year = json['year'];
    final l$subtitle = json['subtitle'];
    final l$seasonNumber = json['seasonNumber'];
    final l$episodeNumber = json['episodeNumber'];
    final l$parentId = json['parentId'];
    final l$score = json['score'];
    final l$artwork = json['artwork'];
    final l$$__typename = json['__typename'];
    return Query$Search$search$sections$results(
      id: (l$id as String),
      type: fromJson$Enum$SearchResultType((l$type as String)),
      title: (l$title as String),
      year: (l$year as int?),
      subtitle: (l$subtitle as String?),
      seasonNumber: (l$seasonNumber as int?),
      episodeNumber: (l$episodeNumber as int?),
      parentId: (l$parentId as String?),
      score: (l$score as num?)?.toDouble(),
      artwork: l$artwork == null
          ? null
          : Fragment$ArtworkFragment.fromJson(
              (l$artwork as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final Enum$SearchResultType type;

  final String title;

  final int? year;

  final String? subtitle;

  final int? seasonNumber;

  final int? episodeNumber;

  final String? parentId;

  final double? score;

  final Fragment$ArtworkFragment? artwork;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$type = type;
    _resultData['type'] = toJson$Enum$SearchResultType(l$type);
    final l$title = title;
    _resultData['title'] = l$title;
    final l$year = year;
    _resultData['year'] = l$year;
    final l$subtitle = subtitle;
    _resultData['subtitle'] = l$subtitle;
    final l$seasonNumber = seasonNumber;
    _resultData['seasonNumber'] = l$seasonNumber;
    final l$episodeNumber = episodeNumber;
    _resultData['episodeNumber'] = l$episodeNumber;
    final l$parentId = parentId;
    _resultData['parentId'] = l$parentId;
    final l$score = score;
    _resultData['score'] = l$score;
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
    final l$subtitle = subtitle;
    final l$seasonNumber = seasonNumber;
    final l$episodeNumber = episodeNumber;
    final l$parentId = parentId;
    final l$score = score;
    final l$artwork = artwork;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$type,
      l$title,
      l$year,
      l$subtitle,
      l$seasonNumber,
      l$episodeNumber,
      l$parentId,
      l$score,
      l$artwork,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$Search$search$sections$results ||
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
    final l$subtitle = subtitle;
    final lOther$subtitle = other.subtitle;
    if (l$subtitle != lOther$subtitle) {
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
    final l$parentId = parentId;
    final lOther$parentId = other.parentId;
    if (l$parentId != lOther$parentId) {
      return false;
    }
    final l$score = score;
    final lOther$score = other.score;
    if (l$score != lOther$score) {
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

extension UtilityExtension$Query$Search$search$sections$results
    on Query$Search$search$sections$results {
  CopyWith$Query$Search$search$sections$results<
          Query$Search$search$sections$results>
      get copyWith =>
          CopyWith$Query$Search$search$sections$results(this, (i) => i);
}

abstract class CopyWith$Query$Search$search$sections$results<TRes> {
  factory CopyWith$Query$Search$search$sections$results(
    Query$Search$search$sections$results instance,
    TRes Function(Query$Search$search$sections$results) then,
  ) = _CopyWithImpl$Query$Search$search$sections$results;

  factory CopyWith$Query$Search$search$sections$results.stub(TRes res) =
      _CopyWithStubImpl$Query$Search$search$sections$results;

  TRes call({
    String? id,
    Enum$SearchResultType? type,
    String? title,
    int? year,
    String? subtitle,
    int? seasonNumber,
    int? episodeNumber,
    String? parentId,
    double? score,
    Fragment$ArtworkFragment? artwork,
    String? $__typename,
  });
  CopyWith$Fragment$ArtworkFragment<TRes> get artwork;
}

class _CopyWithImpl$Query$Search$search$sections$results<TRes>
    implements CopyWith$Query$Search$search$sections$results<TRes> {
  _CopyWithImpl$Query$Search$search$sections$results(
    this._instance,
    this._then,
  );

  final Query$Search$search$sections$results _instance;

  final TRes Function(Query$Search$search$sections$results) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? type = _undefined,
    Object? title = _undefined,
    Object? year = _undefined,
    Object? subtitle = _undefined,
    Object? seasonNumber = _undefined,
    Object? episodeNumber = _undefined,
    Object? parentId = _undefined,
    Object? score = _undefined,
    Object? artwork = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Query$Search$search$sections$results(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          type: type == _undefined || type == null
              ? _instance.type
              : (type as Enum$SearchResultType),
          title: title == _undefined || title == null
              ? _instance.title
              : (title as String),
          year: year == _undefined ? _instance.year : (year as int?),
          subtitle: subtitle == _undefined
              ? _instance.subtitle
              : (subtitle as String?),
          seasonNumber: seasonNumber == _undefined
              ? _instance.seasonNumber
              : (seasonNumber as int?),
          episodeNumber: episodeNumber == _undefined
              ? _instance.episodeNumber
              : (episodeNumber as int?),
          parentId: parentId == _undefined
              ? _instance.parentId
              : (parentId as String?),
          score: score == _undefined ? _instance.score : (score as double?),
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

class _CopyWithStubImpl$Query$Search$search$sections$results<TRes>
    implements CopyWith$Query$Search$search$sections$results<TRes> {
  _CopyWithStubImpl$Query$Search$search$sections$results(this._res);

  TRes _res;

  call({
    String? id,
    Enum$SearchResultType? type,
    String? title,
    int? year,
    String? subtitle,
    int? seasonNumber,
    int? episodeNumber,
    String? parentId,
    double? score,
    Fragment$ArtworkFragment? artwork,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Fragment$ArtworkFragment<TRes> get artwork =>
      CopyWith$Fragment$ArtworkFragment.stub(_res);
}
