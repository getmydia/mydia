import 'package:gql/ast.dart';

class Variables$Mutation$DownloadOptions {
  factory Variables$Mutation$DownloadOptions({
    required String contentType,
    required String id,
  }) =>
      Variables$Mutation$DownloadOptions._({
        r'contentType': contentType,
        r'id': id,
      });

  Variables$Mutation$DownloadOptions._(this._$data);

  factory Variables$Mutation$DownloadOptions.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$contentType = data['contentType'];
    result$data['contentType'] = (l$contentType as String);
    final l$id = data['id'];
    result$data['id'] = (l$id as String);
    return Variables$Mutation$DownloadOptions._(result$data);
  }

  Map<String, dynamic> _$data;

  String get contentType => (_$data['contentType'] as String);

  String get id => (_$data['id'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$contentType = contentType;
    result$data['contentType'] = l$contentType;
    final l$id = id;
    result$data['id'] = l$id;
    return result$data;
  }

  CopyWith$Variables$Mutation$DownloadOptions<
          Variables$Mutation$DownloadOptions>
      get copyWith =>
          CopyWith$Variables$Mutation$DownloadOptions(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$DownloadOptions ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$contentType = contentType;
    final lOther$contentType = other.contentType;
    if (l$contentType != lOther$contentType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$contentType = contentType;
    final l$id = id;
    return Object.hashAll([l$contentType, l$id]);
  }
}

abstract class CopyWith$Variables$Mutation$DownloadOptions<TRes> {
  factory CopyWith$Variables$Mutation$DownloadOptions(
    Variables$Mutation$DownloadOptions instance,
    TRes Function(Variables$Mutation$DownloadOptions) then,
  ) = _CopyWithImpl$Variables$Mutation$DownloadOptions;

  factory CopyWith$Variables$Mutation$DownloadOptions.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$DownloadOptions;

  TRes call({String? contentType, String? id});
}

class _CopyWithImpl$Variables$Mutation$DownloadOptions<TRes>
    implements CopyWith$Variables$Mutation$DownloadOptions<TRes> {
  _CopyWithImpl$Variables$Mutation$DownloadOptions(this._instance, this._then);

  final Variables$Mutation$DownloadOptions _instance;

  final TRes Function(Variables$Mutation$DownloadOptions) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? contentType = _undefined, Object? id = _undefined}) =>
      _then(
        Variables$Mutation$DownloadOptions._({
          ..._instance._$data,
          if (contentType != _undefined && contentType != null)
            'contentType': (contentType as String),
          if (id != _undefined && id != null) 'id': (id as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$DownloadOptions<TRes>
    implements CopyWith$Variables$Mutation$DownloadOptions<TRes> {
  _CopyWithStubImpl$Variables$Mutation$DownloadOptions(this._res);

  TRes _res;

  call({String? contentType, String? id}) => _res;
}

class Mutation$DownloadOptions {
  Mutation$DownloadOptions({
    this.downloadOptions,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$DownloadOptions.fromJson(Map<String, dynamic> json) {
    final l$downloadOptions = json['downloadOptions'];
    final l$$__typename = json['__typename'];
    return Mutation$DownloadOptions(
      downloadOptions: (l$downloadOptions as List<dynamic>?)
          ?.map(
            (e) => Mutation$DownloadOptions$downloadOptions.fromJson(
              (e as Map<String, dynamic>),
            ),
          )
          .toList(),
      $__typename: (l$$__typename as String),
    );
  }

  final List<Mutation$DownloadOptions$downloadOptions>? downloadOptions;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$downloadOptions = downloadOptions;
    _resultData['downloadOptions'] =
        l$downloadOptions?.map((e) => e.toJson()).toList();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$downloadOptions = downloadOptions;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$downloadOptions == null
          ? null
          : Object.hashAll(l$downloadOptions.map((v) => v)),
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$DownloadOptions ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$downloadOptions = downloadOptions;
    final lOther$downloadOptions = other.downloadOptions;
    if (l$downloadOptions != null && lOther$downloadOptions != null) {
      if (l$downloadOptions.length != lOther$downloadOptions.length) {
        return false;
      }
      for (int i = 0; i < l$downloadOptions.length; i++) {
        final l$downloadOptions$entry = l$downloadOptions[i];
        final lOther$downloadOptions$entry = lOther$downloadOptions[i];
        if (l$downloadOptions$entry != lOther$downloadOptions$entry) {
          return false;
        }
      }
    } else if (l$downloadOptions != lOther$downloadOptions) {
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

extension UtilityExtension$Mutation$DownloadOptions
    on Mutation$DownloadOptions {
  CopyWith$Mutation$DownloadOptions<Mutation$DownloadOptions> get copyWith =>
      CopyWith$Mutation$DownloadOptions(this, (i) => i);
}

abstract class CopyWith$Mutation$DownloadOptions<TRes> {
  factory CopyWith$Mutation$DownloadOptions(
    Mutation$DownloadOptions instance,
    TRes Function(Mutation$DownloadOptions) then,
  ) = _CopyWithImpl$Mutation$DownloadOptions;

  factory CopyWith$Mutation$DownloadOptions.stub(TRes res) =
      _CopyWithStubImpl$Mutation$DownloadOptions;

  TRes call({
    List<Mutation$DownloadOptions$downloadOptions>? downloadOptions,
    String? $__typename,
  });
  TRes downloadOptions(
    Iterable<Mutation$DownloadOptions$downloadOptions>? Function(
      Iterable<
          CopyWith$Mutation$DownloadOptions$downloadOptions<
              Mutation$DownloadOptions$downloadOptions>>?,
    ) _fn,
  );
}

class _CopyWithImpl$Mutation$DownloadOptions<TRes>
    implements CopyWith$Mutation$DownloadOptions<TRes> {
  _CopyWithImpl$Mutation$DownloadOptions(this._instance, this._then);

  final Mutation$DownloadOptions _instance;

  final TRes Function(Mutation$DownloadOptions) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? downloadOptions = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$DownloadOptions(
          downloadOptions: downloadOptions == _undefined
              ? _instance.downloadOptions
              : (downloadOptions
                  as List<Mutation$DownloadOptions$downloadOptions>?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  TRes downloadOptions(
    Iterable<Mutation$DownloadOptions$downloadOptions>? Function(
      Iterable<
          CopyWith$Mutation$DownloadOptions$downloadOptions<
              Mutation$DownloadOptions$downloadOptions>>?,
    ) _fn,
  ) =>
      call(
        downloadOptions: _fn(
          _instance.downloadOptions?.map(
            (e) =>
                CopyWith$Mutation$DownloadOptions$downloadOptions(e, (i) => i),
          ),
        )?.toList(),
      );
}

class _CopyWithStubImpl$Mutation$DownloadOptions<TRes>
    implements CopyWith$Mutation$DownloadOptions<TRes> {
  _CopyWithStubImpl$Mutation$DownloadOptions(this._res);

  TRes _res;

  call({
    List<Mutation$DownloadOptions$downloadOptions>? downloadOptions,
    String? $__typename,
  }) =>
      _res;

  downloadOptions(_fn) => _res;
}

const documentNodeMutationDownloadOptions = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'DownloadOptions'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'contentType')),
          type: NamedTypeNode(name: NameNode(value: 'String'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'id')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'downloadOptions'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'contentType'),
                value: VariableNode(name: NameNode(value: 'contentType')),
              ),
              ArgumentNode(
                name: NameNode(value: 'id'),
                value: VariableNode(name: NameNode(value: 'id')),
              ),
            ],
            directives: [],
            selectionSet: SelectionSetNode(
              selections: [
                FieldNode(
                  name: NameNode(value: 'resolution'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'label'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'estimatedSize'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'transcodeStatus'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'transcodeProgress'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'actualSize'),
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

class Mutation$DownloadOptions$downloadOptions {
  Mutation$DownloadOptions$downloadOptions({
    required this.resolution,
    required this.label,
    required this.estimatedSize,
    this.transcodeStatus,
    this.transcodeProgress,
    this.actualSize,
    this.$__typename = 'DownloadOption',
  });

  factory Mutation$DownloadOptions$downloadOptions.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$resolution = json['resolution'];
    final l$label = json['label'];
    final l$estimatedSize = json['estimatedSize'];
    final l$transcodeStatus = json['transcodeStatus'];
    final l$transcodeProgress = json['transcodeProgress'];
    final l$actualSize = json['actualSize'];
    final l$$__typename = json['__typename'];
    return Mutation$DownloadOptions$downloadOptions(
      resolution: (l$resolution as String),
      label: (l$label as String),
      estimatedSize: (l$estimatedSize as int),
      transcodeStatus: (l$transcodeStatus as String?),
      transcodeProgress: (l$transcodeProgress as num?)?.toDouble(),
      actualSize: (l$actualSize as int?),
      $__typename: (l$$__typename as String),
    );
  }

  final String resolution;

  final String label;

  final int estimatedSize;

  final String? transcodeStatus;

  final double? transcodeProgress;

  final int? actualSize;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$resolution = resolution;
    _resultData['resolution'] = l$resolution;
    final l$label = label;
    _resultData['label'] = l$label;
    final l$estimatedSize = estimatedSize;
    _resultData['estimatedSize'] = l$estimatedSize;
    final l$transcodeStatus = transcodeStatus;
    _resultData['transcodeStatus'] = l$transcodeStatus;
    final l$transcodeProgress = transcodeProgress;
    _resultData['transcodeProgress'] = l$transcodeProgress;
    final l$actualSize = actualSize;
    _resultData['actualSize'] = l$actualSize;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$resolution = resolution;
    final l$label = label;
    final l$estimatedSize = estimatedSize;
    final l$transcodeStatus = transcodeStatus;
    final l$transcodeProgress = transcodeProgress;
    final l$actualSize = actualSize;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$resolution,
      l$label,
      l$estimatedSize,
      l$transcodeStatus,
      l$transcodeProgress,
      l$actualSize,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$DownloadOptions$downloadOptions ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$resolution = resolution;
    final lOther$resolution = other.resolution;
    if (l$resolution != lOther$resolution) {
      return false;
    }
    final l$label = label;
    final lOther$label = other.label;
    if (l$label != lOther$label) {
      return false;
    }
    final l$estimatedSize = estimatedSize;
    final lOther$estimatedSize = other.estimatedSize;
    if (l$estimatedSize != lOther$estimatedSize) {
      return false;
    }
    final l$transcodeStatus = transcodeStatus;
    final lOther$transcodeStatus = other.transcodeStatus;
    if (l$transcodeStatus != lOther$transcodeStatus) {
      return false;
    }
    final l$transcodeProgress = transcodeProgress;
    final lOther$transcodeProgress = other.transcodeProgress;
    if (l$transcodeProgress != lOther$transcodeProgress) {
      return false;
    }
    final l$actualSize = actualSize;
    final lOther$actualSize = other.actualSize;
    if (l$actualSize != lOther$actualSize) {
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

extension UtilityExtension$Mutation$DownloadOptions$downloadOptions
    on Mutation$DownloadOptions$downloadOptions {
  CopyWith$Mutation$DownloadOptions$downloadOptions<
          Mutation$DownloadOptions$downloadOptions>
      get copyWith =>
          CopyWith$Mutation$DownloadOptions$downloadOptions(this, (i) => i);
}

abstract class CopyWith$Mutation$DownloadOptions$downloadOptions<TRes> {
  factory CopyWith$Mutation$DownloadOptions$downloadOptions(
    Mutation$DownloadOptions$downloadOptions instance,
    TRes Function(Mutation$DownloadOptions$downloadOptions) then,
  ) = _CopyWithImpl$Mutation$DownloadOptions$downloadOptions;

  factory CopyWith$Mutation$DownloadOptions$downloadOptions.stub(TRes res) =
      _CopyWithStubImpl$Mutation$DownloadOptions$downloadOptions;

  TRes call({
    String? resolution,
    String? label,
    int? estimatedSize,
    String? transcodeStatus,
    double? transcodeProgress,
    int? actualSize,
    String? $__typename,
  });
}

class _CopyWithImpl$Mutation$DownloadOptions$downloadOptions<TRes>
    implements CopyWith$Mutation$DownloadOptions$downloadOptions<TRes> {
  _CopyWithImpl$Mutation$DownloadOptions$downloadOptions(
    this._instance,
    this._then,
  );

  final Mutation$DownloadOptions$downloadOptions _instance;

  final TRes Function(Mutation$DownloadOptions$downloadOptions) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? resolution = _undefined,
    Object? label = _undefined,
    Object? estimatedSize = _undefined,
    Object? transcodeStatus = _undefined,
    Object? transcodeProgress = _undefined,
    Object? actualSize = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$DownloadOptions$downloadOptions(
          resolution: resolution == _undefined || resolution == null
              ? _instance.resolution
              : (resolution as String),
          label: label == _undefined || label == null
              ? _instance.label
              : (label as String),
          estimatedSize: estimatedSize == _undefined || estimatedSize == null
              ? _instance.estimatedSize
              : (estimatedSize as int),
          transcodeStatus: transcodeStatus == _undefined
              ? _instance.transcodeStatus
              : (transcodeStatus as String?),
          transcodeProgress: transcodeProgress == _undefined
              ? _instance.transcodeProgress
              : (transcodeProgress as double?),
          actualSize: actualSize == _undefined
              ? _instance.actualSize
              : (actualSize as int?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$DownloadOptions$downloadOptions<TRes>
    implements CopyWith$Mutation$DownloadOptions$downloadOptions<TRes> {
  _CopyWithStubImpl$Mutation$DownloadOptions$downloadOptions(this._res);

  TRes _res;

  call({
    String? resolution,
    String? label,
    int? estimatedSize,
    String? transcodeStatus,
    double? transcodeProgress,
    int? actualSize,
    String? $__typename,
  }) =>
      _res;
}
