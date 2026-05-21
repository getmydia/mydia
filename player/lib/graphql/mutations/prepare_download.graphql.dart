import 'package:gql/ast.dart';

class Variables$Mutation$PrepareDownload {
  factory Variables$Mutation$PrepareDownload({
    required String contentType,
    required String id,
    String? resolution,
  }) =>
      Variables$Mutation$PrepareDownload._({
        r'contentType': contentType,
        r'id': id,
        if (resolution != null) r'resolution': resolution,
      });

  Variables$Mutation$PrepareDownload._(this._$data);

  factory Variables$Mutation$PrepareDownload.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$contentType = data['contentType'];
    result$data['contentType'] = (l$contentType as String);
    final l$id = data['id'];
    result$data['id'] = (l$id as String);
    if (data.containsKey('resolution')) {
      final l$resolution = data['resolution'];
      result$data['resolution'] = (l$resolution as String?);
    }
    return Variables$Mutation$PrepareDownload._(result$data);
  }

  Map<String, dynamic> _$data;

  String get contentType => (_$data['contentType'] as String);

  String get id => (_$data['id'] as String);

  String? get resolution => (_$data['resolution'] as String?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$contentType = contentType;
    result$data['contentType'] = l$contentType;
    final l$id = id;
    result$data['id'] = l$id;
    if (_$data.containsKey('resolution')) {
      final l$resolution = resolution;
      result$data['resolution'] = l$resolution;
    }
    return result$data;
  }

  CopyWith$Variables$Mutation$PrepareDownload<
          Variables$Mutation$PrepareDownload>
      get copyWith =>
          CopyWith$Variables$Mutation$PrepareDownload(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$PrepareDownload ||
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
    final l$resolution = resolution;
    final lOther$resolution = other.resolution;
    if (_$data.containsKey('resolution') !=
        other._$data.containsKey('resolution')) {
      return false;
    }
    if (l$resolution != lOther$resolution) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$contentType = contentType;
    final l$id = id;
    final l$resolution = resolution;
    return Object.hashAll([
      l$contentType,
      l$id,
      _$data.containsKey('resolution') ? l$resolution : const {},
    ]);
  }
}

abstract class CopyWith$Variables$Mutation$PrepareDownload<TRes> {
  factory CopyWith$Variables$Mutation$PrepareDownload(
    Variables$Mutation$PrepareDownload instance,
    TRes Function(Variables$Mutation$PrepareDownload) then,
  ) = _CopyWithImpl$Variables$Mutation$PrepareDownload;

  factory CopyWith$Variables$Mutation$PrepareDownload.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$PrepareDownload;

  TRes call({String? contentType, String? id, String? resolution});
}

class _CopyWithImpl$Variables$Mutation$PrepareDownload<TRes>
    implements CopyWith$Variables$Mutation$PrepareDownload<TRes> {
  _CopyWithImpl$Variables$Mutation$PrepareDownload(this._instance, this._then);

  final Variables$Mutation$PrepareDownload _instance;

  final TRes Function(Variables$Mutation$PrepareDownload) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? contentType = _undefined,
    Object? id = _undefined,
    Object? resolution = _undefined,
  }) =>
      _then(
        Variables$Mutation$PrepareDownload._({
          ..._instance._$data,
          if (contentType != _undefined && contentType != null)
            'contentType': (contentType as String),
          if (id != _undefined && id != null) 'id': (id as String),
          if (resolution != _undefined) 'resolution': (resolution as String?),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$PrepareDownload<TRes>
    implements CopyWith$Variables$Mutation$PrepareDownload<TRes> {
  _CopyWithStubImpl$Variables$Mutation$PrepareDownload(this._res);

  TRes _res;

  call({String? contentType, String? id, String? resolution}) => _res;
}

class Mutation$PrepareDownload {
  Mutation$PrepareDownload({
    this.prepareDownload,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$PrepareDownload.fromJson(Map<String, dynamic> json) {
    final l$prepareDownload = json['prepareDownload'];
    final l$$__typename = json['__typename'];
    return Mutation$PrepareDownload(
      prepareDownload: l$prepareDownload == null
          ? null
          : Mutation$PrepareDownload$prepareDownload.fromJson(
              (l$prepareDownload as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$PrepareDownload$prepareDownload? prepareDownload;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$prepareDownload = prepareDownload;
    _resultData['prepareDownload'] = l$prepareDownload?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$prepareDownload = prepareDownload;
    final l$$__typename = $__typename;
    return Object.hashAll([l$prepareDownload, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$PrepareDownload ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$prepareDownload = prepareDownload;
    final lOther$prepareDownload = other.prepareDownload;
    if (l$prepareDownload != lOther$prepareDownload) {
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

extension UtilityExtension$Mutation$PrepareDownload
    on Mutation$PrepareDownload {
  CopyWith$Mutation$PrepareDownload<Mutation$PrepareDownload> get copyWith =>
      CopyWith$Mutation$PrepareDownload(this, (i) => i);
}

abstract class CopyWith$Mutation$PrepareDownload<TRes> {
  factory CopyWith$Mutation$PrepareDownload(
    Mutation$PrepareDownload instance,
    TRes Function(Mutation$PrepareDownload) then,
  ) = _CopyWithImpl$Mutation$PrepareDownload;

  factory CopyWith$Mutation$PrepareDownload.stub(TRes res) =
      _CopyWithStubImpl$Mutation$PrepareDownload;

  TRes call({
    Mutation$PrepareDownload$prepareDownload? prepareDownload,
    String? $__typename,
  });
  CopyWith$Mutation$PrepareDownload$prepareDownload<TRes> get prepareDownload;
}

class _CopyWithImpl$Mutation$PrepareDownload<TRes>
    implements CopyWith$Mutation$PrepareDownload<TRes> {
  _CopyWithImpl$Mutation$PrepareDownload(this._instance, this._then);

  final Mutation$PrepareDownload _instance;

  final TRes Function(Mutation$PrepareDownload) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? prepareDownload = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$PrepareDownload(
          prepareDownload: prepareDownload == _undefined
              ? _instance.prepareDownload
              : (prepareDownload as Mutation$PrepareDownload$prepareDownload?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$PrepareDownload$prepareDownload<TRes> get prepareDownload {
    final local$prepareDownload = _instance.prepareDownload;
    return local$prepareDownload == null
        ? CopyWith$Mutation$PrepareDownload$prepareDownload.stub(
            _then(_instance),
          )
        : CopyWith$Mutation$PrepareDownload$prepareDownload(
            local$prepareDownload,
            (e) => call(prepareDownload: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$PrepareDownload<TRes>
    implements CopyWith$Mutation$PrepareDownload<TRes> {
  _CopyWithStubImpl$Mutation$PrepareDownload(this._res);

  TRes _res;

  call({
    Mutation$PrepareDownload$prepareDownload? prepareDownload,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$PrepareDownload$prepareDownload<TRes> get prepareDownload =>
      CopyWith$Mutation$PrepareDownload$prepareDownload.stub(_res);
}

const documentNodeMutationPrepareDownload = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'PrepareDownload'),
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
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'resolution')),
          type: NamedTypeNode(
            name: NameNode(value: 'String'),
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
            name: NameNode(value: 'prepareDownload'),
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
              ArgumentNode(
                name: NameNode(value: 'resolution'),
                value: VariableNode(name: NameNode(value: 'resolution')),
              ),
            ],
            directives: [],
            selectionSet: SelectionSetNode(
              selections: [
                FieldNode(
                  name: NameNode(value: 'jobId'),
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
                  name: NameNode(value: 'progress'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'fileSize'),
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

class Mutation$PrepareDownload$prepareDownload {
  Mutation$PrepareDownload$prepareDownload({
    required this.jobId,
    required this.status,
    required this.progress,
    this.fileSize,
    this.$__typename = 'PrepareDownloadResult',
  });

  factory Mutation$PrepareDownload$prepareDownload.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$jobId = json['jobId'];
    final l$status = json['status'];
    final l$progress = json['progress'];
    final l$fileSize = json['fileSize'];
    final l$$__typename = json['__typename'];
    return Mutation$PrepareDownload$prepareDownload(
      jobId: (l$jobId as String),
      status: (l$status as String),
      progress: (l$progress as num).toDouble(),
      fileSize: (l$fileSize as int?),
      $__typename: (l$$__typename as String),
    );
  }

  final String jobId;

  final String status;

  final double progress;

  final int? fileSize;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$jobId = jobId;
    _resultData['jobId'] = l$jobId;
    final l$status = status;
    _resultData['status'] = l$status;
    final l$progress = progress;
    _resultData['progress'] = l$progress;
    final l$fileSize = fileSize;
    _resultData['fileSize'] = l$fileSize;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$jobId = jobId;
    final l$status = status;
    final l$progress = progress;
    final l$fileSize = fileSize;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$jobId,
      l$status,
      l$progress,
      l$fileSize,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$PrepareDownload$prepareDownload ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$jobId = jobId;
    final lOther$jobId = other.jobId;
    if (l$jobId != lOther$jobId) {
      return false;
    }
    final l$status = status;
    final lOther$status = other.status;
    if (l$status != lOther$status) {
      return false;
    }
    final l$progress = progress;
    final lOther$progress = other.progress;
    if (l$progress != lOther$progress) {
      return false;
    }
    final l$fileSize = fileSize;
    final lOther$fileSize = other.fileSize;
    if (l$fileSize != lOther$fileSize) {
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

extension UtilityExtension$Mutation$PrepareDownload$prepareDownload
    on Mutation$PrepareDownload$prepareDownload {
  CopyWith$Mutation$PrepareDownload$prepareDownload<
          Mutation$PrepareDownload$prepareDownload>
      get copyWith =>
          CopyWith$Mutation$PrepareDownload$prepareDownload(this, (i) => i);
}

abstract class CopyWith$Mutation$PrepareDownload$prepareDownload<TRes> {
  factory CopyWith$Mutation$PrepareDownload$prepareDownload(
    Mutation$PrepareDownload$prepareDownload instance,
    TRes Function(Mutation$PrepareDownload$prepareDownload) then,
  ) = _CopyWithImpl$Mutation$PrepareDownload$prepareDownload;

  factory CopyWith$Mutation$PrepareDownload$prepareDownload.stub(TRes res) =
      _CopyWithStubImpl$Mutation$PrepareDownload$prepareDownload;

  TRes call({
    String? jobId,
    String? status,
    double? progress,
    int? fileSize,
    String? $__typename,
  });
}

class _CopyWithImpl$Mutation$PrepareDownload$prepareDownload<TRes>
    implements CopyWith$Mutation$PrepareDownload$prepareDownload<TRes> {
  _CopyWithImpl$Mutation$PrepareDownload$prepareDownload(
    this._instance,
    this._then,
  );

  final Mutation$PrepareDownload$prepareDownload _instance;

  final TRes Function(Mutation$PrepareDownload$prepareDownload) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? jobId = _undefined,
    Object? status = _undefined,
    Object? progress = _undefined,
    Object? fileSize = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$PrepareDownload$prepareDownload(
          jobId: jobId == _undefined || jobId == null
              ? _instance.jobId
              : (jobId as String),
          status: status == _undefined || status == null
              ? _instance.status
              : (status as String),
          progress: progress == _undefined || progress == null
              ? _instance.progress
              : (progress as double),
          fileSize:
              fileSize == _undefined ? _instance.fileSize : (fileSize as int?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$PrepareDownload$prepareDownload<TRes>
    implements CopyWith$Mutation$PrepareDownload$prepareDownload<TRes> {
  _CopyWithStubImpl$Mutation$PrepareDownload$prepareDownload(this._res);

  TRes _res;

  call({
    String? jobId,
    String? status,
    double? progress,
    int? fileSize,
    String? $__typename,
  }) =>
      _res;
}
