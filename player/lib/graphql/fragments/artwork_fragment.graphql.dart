import 'package:gql/ast.dart';

class Fragment$ArtworkFragment {
  Fragment$ArtworkFragment({
    this.posterUrl,
    this.backdropUrl,
    this.thumbnailUrl,
    this.$__typename = 'Artwork',
  });

  factory Fragment$ArtworkFragment.fromJson(Map<String, dynamic> json) {
    final l$posterUrl = json['posterUrl'];
    final l$backdropUrl = json['backdropUrl'];
    final l$thumbnailUrl = json['thumbnailUrl'];
    final l$$__typename = json['__typename'];
    return Fragment$ArtworkFragment(
      posterUrl: (l$posterUrl as String?),
      backdropUrl: (l$backdropUrl as String?),
      thumbnailUrl: (l$thumbnailUrl as String?),
      $__typename: (l$$__typename as String),
    );
  }

  final String? posterUrl;

  final String? backdropUrl;

  final String? thumbnailUrl;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$posterUrl = posterUrl;
    _resultData['posterUrl'] = l$posterUrl;
    final l$backdropUrl = backdropUrl;
    _resultData['backdropUrl'] = l$backdropUrl;
    final l$thumbnailUrl = thumbnailUrl;
    _resultData['thumbnailUrl'] = l$thumbnailUrl;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$posterUrl = posterUrl;
    final l$backdropUrl = backdropUrl;
    final l$thumbnailUrl = thumbnailUrl;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$posterUrl,
      l$backdropUrl,
      l$thumbnailUrl,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Fragment$ArtworkFragment ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$posterUrl = posterUrl;
    final lOther$posterUrl = other.posterUrl;
    if (l$posterUrl != lOther$posterUrl) {
      return false;
    }
    final l$backdropUrl = backdropUrl;
    final lOther$backdropUrl = other.backdropUrl;
    if (l$backdropUrl != lOther$backdropUrl) {
      return false;
    }
    final l$thumbnailUrl = thumbnailUrl;
    final lOther$thumbnailUrl = other.thumbnailUrl;
    if (l$thumbnailUrl != lOther$thumbnailUrl) {
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

extension UtilityExtension$Fragment$ArtworkFragment
    on Fragment$ArtworkFragment {
  CopyWith$Fragment$ArtworkFragment<Fragment$ArtworkFragment> get copyWith =>
      CopyWith$Fragment$ArtworkFragment(this, (i) => i);
}

abstract class CopyWith$Fragment$ArtworkFragment<TRes> {
  factory CopyWith$Fragment$ArtworkFragment(
    Fragment$ArtworkFragment instance,
    TRes Function(Fragment$ArtworkFragment) then,
  ) = _CopyWithImpl$Fragment$ArtworkFragment;

  factory CopyWith$Fragment$ArtworkFragment.stub(TRes res) =
      _CopyWithStubImpl$Fragment$ArtworkFragment;

  TRes call({
    String? posterUrl,
    String? backdropUrl,
    String? thumbnailUrl,
    String? $__typename,
  });
}

class _CopyWithImpl$Fragment$ArtworkFragment<TRes>
    implements CopyWith$Fragment$ArtworkFragment<TRes> {
  _CopyWithImpl$Fragment$ArtworkFragment(this._instance, this._then);

  final Fragment$ArtworkFragment _instance;

  final TRes Function(Fragment$ArtworkFragment) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? posterUrl = _undefined,
    Object? backdropUrl = _undefined,
    Object? thumbnailUrl = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Fragment$ArtworkFragment(
          posterUrl: posterUrl == _undefined
              ? _instance.posterUrl
              : (posterUrl as String?),
          backdropUrl: backdropUrl == _undefined
              ? _instance.backdropUrl
              : (backdropUrl as String?),
          thumbnailUrl: thumbnailUrl == _undefined
              ? _instance.thumbnailUrl
              : (thumbnailUrl as String?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Fragment$ArtworkFragment<TRes>
    implements CopyWith$Fragment$ArtworkFragment<TRes> {
  _CopyWithStubImpl$Fragment$ArtworkFragment(this._res);

  TRes _res;

  call({
    String? posterUrl,
    String? backdropUrl,
    String? thumbnailUrl,
    String? $__typename,
  }) =>
      _res;
}

const fragmentDefinitionArtworkFragment = FragmentDefinitionNode(
  name: NameNode(value: 'ArtworkFragment'),
  typeCondition: TypeConditionNode(
    on: NamedTypeNode(name: NameNode(value: 'Artwork'), isNonNull: false),
  ),
  directives: [],
  selectionSet: SelectionSetNode(
    selections: [
      FieldNode(
        name: NameNode(value: 'posterUrl'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
      FieldNode(
        name: NameNode(value: 'backdropUrl'),
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
        name: NameNode(value: '__typename'),
        alias: null,
        arguments: [],
        directives: [],
        selectionSet: null,
      ),
    ],
  ),
);
const documentNodeFragmentArtworkFragment = DocumentNode(
  definitions: [fragmentDefinitionArtworkFragment],
);
