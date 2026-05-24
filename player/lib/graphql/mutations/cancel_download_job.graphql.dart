import 'package:gql/ast.dart';

class Variables$Mutation$CancelDownloadJob {
  factory Variables$Mutation$CancelDownloadJob({required String jobId}) =>
      Variables$Mutation$CancelDownloadJob._({r'jobId': jobId});

  Variables$Mutation$CancelDownloadJob._(this._$data);

  factory Variables$Mutation$CancelDownloadJob.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$jobId = data['jobId'];
    result$data['jobId'] = (l$jobId as String);
    return Variables$Mutation$CancelDownloadJob._(result$data);
  }

  Map<String, dynamic> _$data;

  String get jobId => (_$data['jobId'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$jobId = jobId;
    result$data['jobId'] = l$jobId;
    return result$data;
  }

  CopyWith$Variables$Mutation$CancelDownloadJob<
          Variables$Mutation$CancelDownloadJob>
      get copyWith =>
          CopyWith$Variables$Mutation$CancelDownloadJob(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$CancelDownloadJob ||
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

abstract class CopyWith$Variables$Mutation$CancelDownloadJob<TRes> {
  factory CopyWith$Variables$Mutation$CancelDownloadJob(
    Variables$Mutation$CancelDownloadJob instance,
    TRes Function(Variables$Mutation$CancelDownloadJob) then,
  ) = _CopyWithImpl$Variables$Mutation$CancelDownloadJob;

  factory CopyWith$Variables$Mutation$CancelDownloadJob.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$CancelDownloadJob;

  TRes call({String? jobId});
}

class _CopyWithImpl$Variables$Mutation$CancelDownloadJob<TRes>
    implements CopyWith$Variables$Mutation$CancelDownloadJob<TRes> {
  _CopyWithImpl$Variables$Mutation$CancelDownloadJob(
    this._instance,
    this._then,
  );

  final Variables$Mutation$CancelDownloadJob _instance;

  final TRes Function(Variables$Mutation$CancelDownloadJob) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? jobId = _undefined}) => _then(
        Variables$Mutation$CancelDownloadJob._({
          ..._instance._$data,
          if (jobId != _undefined && jobId != null) 'jobId': (jobId as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$CancelDownloadJob<TRes>
    implements CopyWith$Variables$Mutation$CancelDownloadJob<TRes> {
  _CopyWithStubImpl$Variables$Mutation$CancelDownloadJob(this._res);

  TRes _res;

  call({String? jobId}) => _res;
}

class Mutation$CancelDownloadJob {
  Mutation$CancelDownloadJob({
    this.cancelDownloadJob,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$CancelDownloadJob.fromJson(Map<String, dynamic> json) {
    final l$cancelDownloadJob = json['cancelDownloadJob'];
    final l$$__typename = json['__typename'];
    return Mutation$CancelDownloadJob(
      cancelDownloadJob: l$cancelDownloadJob == null
          ? null
          : Mutation$CancelDownloadJob$cancelDownloadJob.fromJson(
              (l$cancelDownloadJob as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$CancelDownloadJob$cancelDownloadJob? cancelDownloadJob;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$cancelDownloadJob = cancelDownloadJob;
    _resultData['cancelDownloadJob'] = l$cancelDownloadJob?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$cancelDownloadJob = cancelDownloadJob;
    final l$$__typename = $__typename;
    return Object.hashAll([l$cancelDownloadJob, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$CancelDownloadJob ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$cancelDownloadJob = cancelDownloadJob;
    final lOther$cancelDownloadJob = other.cancelDownloadJob;
    if (l$cancelDownloadJob != lOther$cancelDownloadJob) {
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

extension UtilityExtension$Mutation$CancelDownloadJob
    on Mutation$CancelDownloadJob {
  CopyWith$Mutation$CancelDownloadJob<Mutation$CancelDownloadJob>
      get copyWith => CopyWith$Mutation$CancelDownloadJob(this, (i) => i);
}

abstract class CopyWith$Mutation$CancelDownloadJob<TRes> {
  factory CopyWith$Mutation$CancelDownloadJob(
    Mutation$CancelDownloadJob instance,
    TRes Function(Mutation$CancelDownloadJob) then,
  ) = _CopyWithImpl$Mutation$CancelDownloadJob;

  factory CopyWith$Mutation$CancelDownloadJob.stub(TRes res) =
      _CopyWithStubImpl$Mutation$CancelDownloadJob;

  TRes call({
    Mutation$CancelDownloadJob$cancelDownloadJob? cancelDownloadJob,
    String? $__typename,
  });
  CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob<TRes>
      get cancelDownloadJob;
}

class _CopyWithImpl$Mutation$CancelDownloadJob<TRes>
    implements CopyWith$Mutation$CancelDownloadJob<TRes> {
  _CopyWithImpl$Mutation$CancelDownloadJob(this._instance, this._then);

  final Mutation$CancelDownloadJob _instance;

  final TRes Function(Mutation$CancelDownloadJob) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? cancelDownloadJob = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$CancelDownloadJob(
          cancelDownloadJob: cancelDownloadJob == _undefined
              ? _instance.cancelDownloadJob
              : (cancelDownloadJob
                  as Mutation$CancelDownloadJob$cancelDownloadJob?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob<TRes>
      get cancelDownloadJob {
    final local$cancelDownloadJob = _instance.cancelDownloadJob;
    return local$cancelDownloadJob == null
        ? CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob.stub(
            _then(_instance),
          )
        : CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob(
            local$cancelDownloadJob,
            (e) => call(cancelDownloadJob: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$CancelDownloadJob<TRes>
    implements CopyWith$Mutation$CancelDownloadJob<TRes> {
  _CopyWithStubImpl$Mutation$CancelDownloadJob(this._res);

  TRes _res;

  call({
    Mutation$CancelDownloadJob$cancelDownloadJob? cancelDownloadJob,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob<TRes>
      get cancelDownloadJob =>
          CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob.stub(_res);
}

const documentNodeMutationCancelDownloadJob = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'CancelDownloadJob'),
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
            name: NameNode(value: 'cancelDownloadJob'),
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
                  name: NameNode(value: 'success'),
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

class Mutation$CancelDownloadJob$cancelDownloadJob {
  Mutation$CancelDownloadJob$cancelDownloadJob({
    required this.success,
    this.$__typename = 'CancelDownloadResult',
  });

  factory Mutation$CancelDownloadJob$cancelDownloadJob.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$success = json['success'];
    final l$$__typename = json['__typename'];
    return Mutation$CancelDownloadJob$cancelDownloadJob(
      success: (l$success as bool),
      $__typename: (l$$__typename as String),
    );
  }

  final bool success;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$success = success;
    _resultData['success'] = l$success;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$success = success;
    final l$$__typename = $__typename;
    return Object.hashAll([l$success, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$CancelDownloadJob$cancelDownloadJob ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$success = success;
    final lOther$success = other.success;
    if (l$success != lOther$success) {
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

extension UtilityExtension$Mutation$CancelDownloadJob$cancelDownloadJob
    on Mutation$CancelDownloadJob$cancelDownloadJob {
  CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob<
          Mutation$CancelDownloadJob$cancelDownloadJob>
      get copyWith =>
          CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob(this, (i) => i);
}

abstract class CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob<TRes> {
  factory CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob(
    Mutation$CancelDownloadJob$cancelDownloadJob instance,
    TRes Function(Mutation$CancelDownloadJob$cancelDownloadJob) then,
  ) = _CopyWithImpl$Mutation$CancelDownloadJob$cancelDownloadJob;

  factory CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob.stub(TRes res) =
      _CopyWithStubImpl$Mutation$CancelDownloadJob$cancelDownloadJob;

  TRes call({bool? success, String? $__typename});
}

class _CopyWithImpl$Mutation$CancelDownloadJob$cancelDownloadJob<TRes>
    implements CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob<TRes> {
  _CopyWithImpl$Mutation$CancelDownloadJob$cancelDownloadJob(
    this._instance,
    this._then,
  );

  final Mutation$CancelDownloadJob$cancelDownloadJob _instance;

  final TRes Function(Mutation$CancelDownloadJob$cancelDownloadJob) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? success = _undefined, Object? $__typename = _undefined}) =>
      _then(
        Mutation$CancelDownloadJob$cancelDownloadJob(
          success: success == _undefined || success == null
              ? _instance.success
              : (success as bool),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$CancelDownloadJob$cancelDownloadJob<TRes>
    implements CopyWith$Mutation$CancelDownloadJob$cancelDownloadJob<TRes> {
  _CopyWithStubImpl$Mutation$CancelDownloadJob$cancelDownloadJob(this._res);

  TRes _res;

  call({bool? success, String? $__typename}) => _res;
}
