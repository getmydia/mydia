import 'package:gql/ast.dart';

class Variables$Mutation$DownloadJobStatus {
  factory Variables$Mutation$DownloadJobStatus({required String jobId}) =>
      Variables$Mutation$DownloadJobStatus._({r'jobId': jobId});

  Variables$Mutation$DownloadJobStatus._(this._$data);

  factory Variables$Mutation$DownloadJobStatus.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$jobId = data['jobId'];
    result$data['jobId'] = (l$jobId as String);
    return Variables$Mutation$DownloadJobStatus._(result$data);
  }

  Map<String, dynamic> _$data;

  String get jobId => (_$data['jobId'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$jobId = jobId;
    result$data['jobId'] = l$jobId;
    return result$data;
  }

  CopyWith$Variables$Mutation$DownloadJobStatus<
          Variables$Mutation$DownloadJobStatus>
      get copyWith =>
          CopyWith$Variables$Mutation$DownloadJobStatus(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$DownloadJobStatus ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$jobId = jobId;
    final lOther$jobId = other.jobId;
    if (l$jobId != lOther$jobId) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$jobId = jobId;
    return Object.hashAll([l$jobId]);
  }
}

abstract class CopyWith$Variables$Mutation$DownloadJobStatus<TRes> {
  factory CopyWith$Variables$Mutation$DownloadJobStatus(
    Variables$Mutation$DownloadJobStatus instance,
    TRes Function(Variables$Mutation$DownloadJobStatus) then,
  ) = _CopyWithImpl$Variables$Mutation$DownloadJobStatus;

  factory CopyWith$Variables$Mutation$DownloadJobStatus.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$DownloadJobStatus;

  TRes call({String? jobId});
}

class _CopyWithImpl$Variables$Mutation$DownloadJobStatus<TRes>
    implements CopyWith$Variables$Mutation$DownloadJobStatus<TRes> {
  _CopyWithImpl$Variables$Mutation$DownloadJobStatus(
    this._instance,
    this._then,
  );

  final Variables$Mutation$DownloadJobStatus _instance;

  final TRes Function(Variables$Mutation$DownloadJobStatus) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? jobId = _undefined}) => _then(
        Variables$Mutation$DownloadJobStatus._({
          ..._instance._$data,
          if (jobId != _undefined && jobId != null) 'jobId': (jobId as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$DownloadJobStatus<TRes>
    implements CopyWith$Variables$Mutation$DownloadJobStatus<TRes> {
  _CopyWithStubImpl$Variables$Mutation$DownloadJobStatus(this._res);

  TRes _res;

  call({String? jobId}) => _res;
}

class Mutation$DownloadJobStatus {
  Mutation$DownloadJobStatus({
    this.downloadJobStatus,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$DownloadJobStatus.fromJson(Map<String, dynamic> json) {
    final l$downloadJobStatus = json['downloadJobStatus'];
    final l$$__typename = json['__typename'];
    return Mutation$DownloadJobStatus(
      downloadJobStatus: l$downloadJobStatus == null
          ? null
          : Mutation$DownloadJobStatus$downloadJobStatus.fromJson(
              (l$downloadJobStatus as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$DownloadJobStatus$downloadJobStatus? downloadJobStatus;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$downloadJobStatus = downloadJobStatus;
    _resultData['downloadJobStatus'] = l$downloadJobStatus?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$downloadJobStatus = downloadJobStatus;
    final l$$__typename = $__typename;
    return Object.hashAll([l$downloadJobStatus, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$DownloadJobStatus ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$downloadJobStatus = downloadJobStatus;
    final lOther$downloadJobStatus = other.downloadJobStatus;
    if (l$downloadJobStatus != lOther$downloadJobStatus) {
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

extension UtilityExtension$Mutation$DownloadJobStatus
    on Mutation$DownloadJobStatus {
  CopyWith$Mutation$DownloadJobStatus<Mutation$DownloadJobStatus>
      get copyWith => CopyWith$Mutation$DownloadJobStatus(this, (i) => i);
}

abstract class CopyWith$Mutation$DownloadJobStatus<TRes> {
  factory CopyWith$Mutation$DownloadJobStatus(
    Mutation$DownloadJobStatus instance,
    TRes Function(Mutation$DownloadJobStatus) then,
  ) = _CopyWithImpl$Mutation$DownloadJobStatus;

  factory CopyWith$Mutation$DownloadJobStatus.stub(TRes res) =
      _CopyWithStubImpl$Mutation$DownloadJobStatus;

  TRes call({
    Mutation$DownloadJobStatus$downloadJobStatus? downloadJobStatus,
    String? $__typename,
  });
  CopyWith$Mutation$DownloadJobStatus$downloadJobStatus<TRes>
      get downloadJobStatus;
}

class _CopyWithImpl$Mutation$DownloadJobStatus<TRes>
    implements CopyWith$Mutation$DownloadJobStatus<TRes> {
  _CopyWithImpl$Mutation$DownloadJobStatus(this._instance, this._then);

  final Mutation$DownloadJobStatus _instance;

  final TRes Function(Mutation$DownloadJobStatus) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? downloadJobStatus = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$DownloadJobStatus(
          downloadJobStatus: downloadJobStatus == _undefined
              ? _instance.downloadJobStatus
              : (downloadJobStatus
                  as Mutation$DownloadJobStatus$downloadJobStatus?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$DownloadJobStatus$downloadJobStatus<TRes>
      get downloadJobStatus {
    final local$downloadJobStatus = _instance.downloadJobStatus;
    return local$downloadJobStatus == null
        ? CopyWith$Mutation$DownloadJobStatus$downloadJobStatus.stub(
            _then(_instance),
          )
        : CopyWith$Mutation$DownloadJobStatus$downloadJobStatus(
            local$downloadJobStatus,
            (e) => call(downloadJobStatus: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$DownloadJobStatus<TRes>
    implements CopyWith$Mutation$DownloadJobStatus<TRes> {
  _CopyWithStubImpl$Mutation$DownloadJobStatus(this._res);

  TRes _res;

  call({
    Mutation$DownloadJobStatus$downloadJobStatus? downloadJobStatus,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$DownloadJobStatus$downloadJobStatus<TRes>
      get downloadJobStatus =>
          CopyWith$Mutation$DownloadJobStatus$downloadJobStatus.stub(_res);
}

const documentNodeMutationDownloadJobStatus = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'DownloadJobStatus'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'jobId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'downloadJobStatus'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'jobId'),
                value: VariableNode(name: NameNode(value: 'jobId')),
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
                  name: NameNode(value: 'error'),
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

class Mutation$DownloadJobStatus$downloadJobStatus {
  Mutation$DownloadJobStatus$downloadJobStatus({
    required this.jobId,
    required this.status,
    required this.progress,
    this.error,
    this.fileSize,
    this.$__typename = 'DownloadJobStatus',
  });

  factory Mutation$DownloadJobStatus$downloadJobStatus.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$jobId = json['jobId'];
    final l$status = json['status'];
    final l$progress = json['progress'];
    final l$error = json['error'];
    final l$fileSize = json['fileSize'];
    final l$$__typename = json['__typename'];
    return Mutation$DownloadJobStatus$downloadJobStatus(
      jobId: (l$jobId as String),
      status: (l$status as String),
      progress: (l$progress as num).toDouble(),
      error: (l$error as String?),
      fileSize: (l$fileSize as int?),
      $__typename: (l$$__typename as String),
    );
  }

  final String jobId;

  final String status;

  final double progress;

  final String? error;

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
    final l$error = error;
    _resultData['error'] = l$error;
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
    final l$error = error;
    final l$fileSize = fileSize;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$jobId,
      l$status,
      l$progress,
      l$error,
      l$fileSize,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$DownloadJobStatus$downloadJobStatus ||
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
    final l$error = error;
    final lOther$error = other.error;
    if (l$error != lOther$error) {
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

extension UtilityExtension$Mutation$DownloadJobStatus$downloadJobStatus
    on Mutation$DownloadJobStatus$downloadJobStatus {
  CopyWith$Mutation$DownloadJobStatus$downloadJobStatus<
          Mutation$DownloadJobStatus$downloadJobStatus>
      get copyWith =>
          CopyWith$Mutation$DownloadJobStatus$downloadJobStatus(this, (i) => i);
}

abstract class CopyWith$Mutation$DownloadJobStatus$downloadJobStatus<TRes> {
  factory CopyWith$Mutation$DownloadJobStatus$downloadJobStatus(
    Mutation$DownloadJobStatus$downloadJobStatus instance,
    TRes Function(Mutation$DownloadJobStatus$downloadJobStatus) then,
  ) = _CopyWithImpl$Mutation$DownloadJobStatus$downloadJobStatus;

  factory CopyWith$Mutation$DownloadJobStatus$downloadJobStatus.stub(TRes res) =
      _CopyWithStubImpl$Mutation$DownloadJobStatus$downloadJobStatus;

  TRes call({
    String? jobId,
    String? status,
    double? progress,
    String? error,
    int? fileSize,
    String? $__typename,
  });
}

class _CopyWithImpl$Mutation$DownloadJobStatus$downloadJobStatus<TRes>
    implements CopyWith$Mutation$DownloadJobStatus$downloadJobStatus<TRes> {
  _CopyWithImpl$Mutation$DownloadJobStatus$downloadJobStatus(
    this._instance,
    this._then,
  );

  final Mutation$DownloadJobStatus$downloadJobStatus _instance;

  final TRes Function(Mutation$DownloadJobStatus$downloadJobStatus) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? jobId = _undefined,
    Object? status = _undefined,
    Object? progress = _undefined,
    Object? error = _undefined,
    Object? fileSize = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$DownloadJobStatus$downloadJobStatus(
          jobId: jobId == _undefined || jobId == null
              ? _instance.jobId
              : (jobId as String),
          status: status == _undefined || status == null
              ? _instance.status
              : (status as String),
          progress: progress == _undefined || progress == null
              ? _instance.progress
              : (progress as double),
          error: error == _undefined ? _instance.error : (error as String?),
          fileSize:
              fileSize == _undefined ? _instance.fileSize : (fileSize as int?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$DownloadJobStatus$downloadJobStatus<TRes>
    implements CopyWith$Mutation$DownloadJobStatus$downloadJobStatus<TRes> {
  _CopyWithStubImpl$Mutation$DownloadJobStatus$downloadJobStatus(this._res);

  TRes _res;

  call({
    String? jobId,
    String? status,
    double? progress,
    String? error,
    int? fileSize,
    String? $__typename,
  }) =>
      _res;
}
