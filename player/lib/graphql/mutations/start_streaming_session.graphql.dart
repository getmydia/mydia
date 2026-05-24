import '../schema.graphql.dart';
import 'package:gql/ast.dart';

class Variables$Mutation$StartStreamingSession {
  factory Variables$Mutation$StartStreamingSession({
    required String fileId,
    required Enum$StreamingStrategy strategy,
    int? maxBitrate,
  }) =>
      Variables$Mutation$StartStreamingSession._({
        r'fileId': fileId,
        r'strategy': strategy,
        if (maxBitrate != null) r'maxBitrate': maxBitrate,
      });

  Variables$Mutation$StartStreamingSession._(this._$data);

  factory Variables$Mutation$StartStreamingSession.fromJson(
    Map<String, dynamic> data,
  ) {
    final result$data = <String, dynamic>{};
    final l$fileId = data['fileId'];
    result$data['fileId'] = (l$fileId as String);
    final l$strategy = data['strategy'];
    result$data['strategy'] = fromJson$Enum$StreamingStrategy(
      (l$strategy as String),
    );
    if (data.containsKey('maxBitrate')) {
      final l$maxBitrate = data['maxBitrate'];
      result$data['maxBitrate'] = (l$maxBitrate as int?);
    }
    return Variables$Mutation$StartStreamingSession._(result$data);
  }

  Map<String, dynamic> _$data;

  String get fileId => (_$data['fileId'] as String);

  Enum$StreamingStrategy get strategy =>
      (_$data['strategy'] as Enum$StreamingStrategy);

  int? get maxBitrate => (_$data['maxBitrate'] as int?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$fileId = fileId;
    result$data['fileId'] = l$fileId;
    final l$strategy = strategy;
    result$data['strategy'] = toJson$Enum$StreamingStrategy(l$strategy);
    if (_$data.containsKey('maxBitrate')) {
      final l$maxBitrate = maxBitrate;
      result$data['maxBitrate'] = l$maxBitrate;
    }
    return result$data;
  }

  CopyWith$Variables$Mutation$StartStreamingSession<
          Variables$Mutation$StartStreamingSession>
      get copyWith =>
          CopyWith$Variables$Mutation$StartStreamingSession(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$StartStreamingSession ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$fileId = fileId;
    final lOther$fileId = other.fileId;
    if (l$fileId != lOther$fileId) {
      return false;
    }
    final l$strategy = strategy;
    final lOther$strategy = other.strategy;
    if (l$strategy != lOther$strategy) {
      return false;
    }
    final l$maxBitrate = maxBitrate;
    final lOther$maxBitrate = other.maxBitrate;
    if (_$data.containsKey('maxBitrate') !=
        other._$data.containsKey('maxBitrate')) {
      return false;
    }
    if (l$maxBitrate != lOther$maxBitrate) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$fileId = fileId;
    final l$strategy = strategy;
    final l$maxBitrate = maxBitrate;
    return Object.hashAll([
      l$fileId,
      l$strategy,
      _$data.containsKey('maxBitrate') ? l$maxBitrate : const {},
    ]);
  }
}

abstract class CopyWith$Variables$Mutation$StartStreamingSession<TRes> {
  factory CopyWith$Variables$Mutation$StartStreamingSession(
    Variables$Mutation$StartStreamingSession instance,
    TRes Function(Variables$Mutation$StartStreamingSession) then,
  ) = _CopyWithImpl$Variables$Mutation$StartStreamingSession;

  factory CopyWith$Variables$Mutation$StartStreamingSession.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$StartStreamingSession;

  TRes call({
    String? fileId,
    Enum$StreamingStrategy? strategy,
    int? maxBitrate,
  });
}

class _CopyWithImpl$Variables$Mutation$StartStreamingSession<TRes>
    implements CopyWith$Variables$Mutation$StartStreamingSession<TRes> {
  _CopyWithImpl$Variables$Mutation$StartStreamingSession(
    this._instance,
    this._then,
  );

  final Variables$Mutation$StartStreamingSession _instance;

  final TRes Function(Variables$Mutation$StartStreamingSession) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? fileId = _undefined,
    Object? strategy = _undefined,
    Object? maxBitrate = _undefined,
  }) =>
      _then(
        Variables$Mutation$StartStreamingSession._({
          ..._instance._$data,
          if (fileId != _undefined && fileId != null)
            'fileId': (fileId as String),
          if (strategy != _undefined && strategy != null)
            'strategy': (strategy as Enum$StreamingStrategy),
          if (maxBitrate != _undefined) 'maxBitrate': (maxBitrate as int?),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$StartStreamingSession<TRes>
    implements CopyWith$Variables$Mutation$StartStreamingSession<TRes> {
  _CopyWithStubImpl$Variables$Mutation$StartStreamingSession(this._res);

  TRes _res;

  call({String? fileId, Enum$StreamingStrategy? strategy, int? maxBitrate}) =>
      _res;
}

class Mutation$StartStreamingSession {
  Mutation$StartStreamingSession({
    this.startStreamingSession,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$StartStreamingSession.fromJson(Map<String, dynamic> json) {
    final l$startStreamingSession = json['startStreamingSession'];
    final l$$__typename = json['__typename'];
    return Mutation$StartStreamingSession(
      startStreamingSession: l$startStreamingSession == null
          ? null
          : Mutation$StartStreamingSession$startStreamingSession.fromJson(
              (l$startStreamingSession as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$StartStreamingSession$startStreamingSession?
      startStreamingSession;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$startStreamingSession = startStreamingSession;
    _resultData['startStreamingSession'] = l$startStreamingSession?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$startStreamingSession = startStreamingSession;
    final l$$__typename = $__typename;
    return Object.hashAll([l$startStreamingSession, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$StartStreamingSession ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$startStreamingSession = startStreamingSession;
    final lOther$startStreamingSession = other.startStreamingSession;
    if (l$startStreamingSession != lOther$startStreamingSession) {
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

extension UtilityExtension$Mutation$StartStreamingSession
    on Mutation$StartStreamingSession {
  CopyWith$Mutation$StartStreamingSession<Mutation$StartStreamingSession>
      get copyWith => CopyWith$Mutation$StartStreamingSession(this, (i) => i);
}

abstract class CopyWith$Mutation$StartStreamingSession<TRes> {
  factory CopyWith$Mutation$StartStreamingSession(
    Mutation$StartStreamingSession instance,
    TRes Function(Mutation$StartStreamingSession) then,
  ) = _CopyWithImpl$Mutation$StartStreamingSession;

  factory CopyWith$Mutation$StartStreamingSession.stub(TRes res) =
      _CopyWithStubImpl$Mutation$StartStreamingSession;

  TRes call({
    Mutation$StartStreamingSession$startStreamingSession? startStreamingSession,
    String? $__typename,
  });
  CopyWith$Mutation$StartStreamingSession$startStreamingSession<TRes>
      get startStreamingSession;
}

class _CopyWithImpl$Mutation$StartStreamingSession<TRes>
    implements CopyWith$Mutation$StartStreamingSession<TRes> {
  _CopyWithImpl$Mutation$StartStreamingSession(this._instance, this._then);

  final Mutation$StartStreamingSession _instance;

  final TRes Function(Mutation$StartStreamingSession) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? startStreamingSession = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$StartStreamingSession(
          startStreamingSession: startStreamingSession == _undefined
              ? _instance.startStreamingSession
              : (startStreamingSession
                  as Mutation$StartStreamingSession$startStreamingSession?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$StartStreamingSession$startStreamingSession<TRes>
      get startStreamingSession {
    final local$startStreamingSession = _instance.startStreamingSession;
    return local$startStreamingSession == null
        ? CopyWith$Mutation$StartStreamingSession$startStreamingSession.stub(
            _then(_instance),
          )
        : CopyWith$Mutation$StartStreamingSession$startStreamingSession(
            local$startStreamingSession,
            (e) => call(startStreamingSession: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$StartStreamingSession<TRes>
    implements CopyWith$Mutation$StartStreamingSession<TRes> {
  _CopyWithStubImpl$Mutation$StartStreamingSession(this._res);

  TRes _res;

  call({
    Mutation$StartStreamingSession$startStreamingSession? startStreamingSession,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$StartStreamingSession$startStreamingSession<TRes>
      get startStreamingSession =>
          CopyWith$Mutation$StartStreamingSession$startStreamingSession.stub(
              _res);
}

const documentNodeMutationStartStreamingSession = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'StartStreamingSession'),
      variableDefinitions: [
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'fileId')),
          type: NamedTypeNode(name: NameNode(value: 'ID'), isNonNull: true),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'strategy')),
          type: NamedTypeNode(
            name: NameNode(value: 'StreamingStrategy'),
            isNonNull: true,
          ),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
        VariableDefinitionNode(
          variable: VariableNode(name: NameNode(value: 'maxBitrate')),
          type: NamedTypeNode(name: NameNode(value: 'Int'), isNonNull: false),
          defaultValue: DefaultValueNode(value: null),
          directives: [],
        ),
      ],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'startStreamingSession'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'fileId'),
                value: VariableNode(name: NameNode(value: 'fileId')),
              ),
              ArgumentNode(
                name: NameNode(value: 'strategy'),
                value: VariableNode(name: NameNode(value: 'strategy')),
              ),
              ArgumentNode(
                name: NameNode(value: 'maxBitrate'),
                value: VariableNode(name: NameNode(value: 'maxBitrate')),
              ),
            ],
            directives: [],
            selectionSet: SelectionSetNode(
              selections: [
                FieldNode(
                  name: NameNode(value: 'sessionId'),
                  alias: null,
                  arguments: [],
                  directives: [],
                  selectionSet: null,
                ),
                FieldNode(
                  name: NameNode(value: 'duration'),
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

class Mutation$StartStreamingSession$startStreamingSession {
  Mutation$StartStreamingSession$startStreamingSession({
    required this.sessionId,
    this.duration,
    this.$__typename = 'StreamingSessionResult',
  });

  factory Mutation$StartStreamingSession$startStreamingSession.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$sessionId = json['sessionId'];
    final l$duration = json['duration'];
    final l$$__typename = json['__typename'];
    return Mutation$StartStreamingSession$startStreamingSession(
      sessionId: (l$sessionId as String),
      duration: (l$duration as num?)?.toDouble(),
      $__typename: (l$$__typename as String),
    );
  }

  final String sessionId;

  final double? duration;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$sessionId = sessionId;
    _resultData['sessionId'] = l$sessionId;
    final l$duration = duration;
    _resultData['duration'] = l$duration;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$sessionId = sessionId;
    final l$duration = duration;
    final l$$__typename = $__typename;
    return Object.hashAll([l$sessionId, l$duration, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$StartStreamingSession$startStreamingSession ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$sessionId = sessionId;
    final lOther$sessionId = other.sessionId;
    if (l$sessionId != lOther$sessionId) {
      return false;
    }
    final l$duration = duration;
    final lOther$duration = other.duration;
    if (l$duration != lOther$duration) {
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

extension UtilityExtension$Mutation$StartStreamingSession$startStreamingSession
    on Mutation$StartStreamingSession$startStreamingSession {
  CopyWith$Mutation$StartStreamingSession$startStreamingSession<
          Mutation$StartStreamingSession$startStreamingSession>
      get copyWith =>
          CopyWith$Mutation$StartStreamingSession$startStreamingSession(
            this,
            (i) => i,
          );
}

abstract class CopyWith$Mutation$StartStreamingSession$startStreamingSession<
    TRes> {
  factory CopyWith$Mutation$StartStreamingSession$startStreamingSession(
    Mutation$StartStreamingSession$startStreamingSession instance,
    TRes Function(Mutation$StartStreamingSession$startStreamingSession) then,
  ) = _CopyWithImpl$Mutation$StartStreamingSession$startStreamingSession;

  factory CopyWith$Mutation$StartStreamingSession$startStreamingSession.stub(
    TRes res,
  ) = _CopyWithStubImpl$Mutation$StartStreamingSession$startStreamingSession;

  TRes call({String? sessionId, double? duration, String? $__typename});
}

class _CopyWithImpl$Mutation$StartStreamingSession$startStreamingSession<TRes>
    implements
        CopyWith$Mutation$StartStreamingSession$startStreamingSession<TRes> {
  _CopyWithImpl$Mutation$StartStreamingSession$startStreamingSession(
    this._instance,
    this._then,
  );

  final Mutation$StartStreamingSession$startStreamingSession _instance;

  final TRes Function(Mutation$StartStreamingSession$startStreamingSession)
      _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? sessionId = _undefined,
    Object? duration = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$StartStreamingSession$startStreamingSession(
          sessionId: sessionId == _undefined || sessionId == null
              ? _instance.sessionId
              : (sessionId as String),
          duration: duration == _undefined
              ? _instance.duration
              : (duration as double?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$StartStreamingSession$startStreamingSession<
        TRes>
    implements
        CopyWith$Mutation$StartStreamingSession$startStreamingSession<TRes> {
  _CopyWithStubImpl$Mutation$StartStreamingSession$startStreamingSession(
    this._res,
  );

  TRes _res;

  call({String? sessionId, double? duration, String? $__typename}) => _res;
}
