import 'package:gql/ast.dart';

class Variables$Mutation$RevokeDevice {
  factory Variables$Mutation$RevokeDevice({required String id}) =>
      Variables$Mutation$RevokeDevice._({r'id': id});

  Variables$Mutation$RevokeDevice._(this._$data);

  factory Variables$Mutation$RevokeDevice.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    final l$id = data['id'];
    result$data['id'] = (l$id as String);
    return Variables$Mutation$RevokeDevice._(result$data);
  }

  Map<String, dynamic> _$data;

  String get id => (_$data['id'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$id = id;
    result$data['id'] = l$id;
    return result$data;
  }

  CopyWith$Variables$Mutation$RevokeDevice<Variables$Mutation$RevokeDevice>
      get copyWith => CopyWith$Variables$Mutation$RevokeDevice(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Variables$Mutation$RevokeDevice ||
        runtimeType != other.runtimeType) {
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
    final l$id = id;
    return Object.hashAll([l$id]);
  }
}

abstract class CopyWith$Variables$Mutation$RevokeDevice<TRes> {
  factory CopyWith$Variables$Mutation$RevokeDevice(
    Variables$Mutation$RevokeDevice instance,
    TRes Function(Variables$Mutation$RevokeDevice) then,
  ) = _CopyWithImpl$Variables$Mutation$RevokeDevice;

  factory CopyWith$Variables$Mutation$RevokeDevice.stub(TRes res) =
      _CopyWithStubImpl$Variables$Mutation$RevokeDevice;

  TRes call({String? id});
}

class _CopyWithImpl$Variables$Mutation$RevokeDevice<TRes>
    implements CopyWith$Variables$Mutation$RevokeDevice<TRes> {
  _CopyWithImpl$Variables$Mutation$RevokeDevice(this._instance, this._then);

  final Variables$Mutation$RevokeDevice _instance;

  final TRes Function(Variables$Mutation$RevokeDevice) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? id = _undefined}) => _then(
        Variables$Mutation$RevokeDevice._({
          ..._instance._$data,
          if (id != _undefined && id != null) 'id': (id as String),
        }),
      );
}

class _CopyWithStubImpl$Variables$Mutation$RevokeDevice<TRes>
    implements CopyWith$Variables$Mutation$RevokeDevice<TRes> {
  _CopyWithStubImpl$Variables$Mutation$RevokeDevice(this._res);

  TRes _res;

  call({String? id}) => _res;
}

class Mutation$RevokeDevice {
  Mutation$RevokeDevice({
    this.revokeDevice,
    this.$__typename = 'RootMutationType',
  });

  factory Mutation$RevokeDevice.fromJson(Map<String, dynamic> json) {
    final l$revokeDevice = json['revokeDevice'];
    final l$$__typename = json['__typename'];
    return Mutation$RevokeDevice(
      revokeDevice: l$revokeDevice == null
          ? null
          : Mutation$RevokeDevice$revokeDevice.fromJson(
              (l$revokeDevice as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final Mutation$RevokeDevice$revokeDevice? revokeDevice;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$revokeDevice = revokeDevice;
    _resultData['revokeDevice'] = l$revokeDevice?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$revokeDevice = revokeDevice;
    final l$$__typename = $__typename;
    return Object.hashAll([l$revokeDevice, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$RevokeDevice || runtimeType != other.runtimeType) {
      return false;
    }
    final l$revokeDevice = revokeDevice;
    final lOther$revokeDevice = other.revokeDevice;
    if (l$revokeDevice != lOther$revokeDevice) {
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

extension UtilityExtension$Mutation$RevokeDevice on Mutation$RevokeDevice {
  CopyWith$Mutation$RevokeDevice<Mutation$RevokeDevice> get copyWith =>
      CopyWith$Mutation$RevokeDevice(this, (i) => i);
}

abstract class CopyWith$Mutation$RevokeDevice<TRes> {
  factory CopyWith$Mutation$RevokeDevice(
    Mutation$RevokeDevice instance,
    TRes Function(Mutation$RevokeDevice) then,
  ) = _CopyWithImpl$Mutation$RevokeDevice;

  factory CopyWith$Mutation$RevokeDevice.stub(TRes res) =
      _CopyWithStubImpl$Mutation$RevokeDevice;

  TRes call({
    Mutation$RevokeDevice$revokeDevice? revokeDevice,
    String? $__typename,
  });
  CopyWith$Mutation$RevokeDevice$revokeDevice<TRes> get revokeDevice;
}

class _CopyWithImpl$Mutation$RevokeDevice<TRes>
    implements CopyWith$Mutation$RevokeDevice<TRes> {
  _CopyWithImpl$Mutation$RevokeDevice(this._instance, this._then);

  final Mutation$RevokeDevice _instance;

  final TRes Function(Mutation$RevokeDevice) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? revokeDevice = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$RevokeDevice(
          revokeDevice: revokeDevice == _undefined
              ? _instance.revokeDevice
              : (revokeDevice as Mutation$RevokeDevice$revokeDevice?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$RevokeDevice$revokeDevice<TRes> get revokeDevice {
    final local$revokeDevice = _instance.revokeDevice;
    return local$revokeDevice == null
        ? CopyWith$Mutation$RevokeDevice$revokeDevice.stub(_then(_instance))
        : CopyWith$Mutation$RevokeDevice$revokeDevice(
            local$revokeDevice,
            (e) => call(revokeDevice: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$RevokeDevice<TRes>
    implements CopyWith$Mutation$RevokeDevice<TRes> {
  _CopyWithStubImpl$Mutation$RevokeDevice(this._res);

  TRes _res;

  call({
    Mutation$RevokeDevice$revokeDevice? revokeDevice,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$RevokeDevice$revokeDevice<TRes> get revokeDevice =>
      CopyWith$Mutation$RevokeDevice$revokeDevice.stub(_res);
}

const documentNodeMutationRevokeDevice = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.mutation,
      name: NameNode(value: 'RevokeDevice'),
      variableDefinitions: [
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
            name: NameNode(value: 'revokeDevice'),
            alias: null,
            arguments: [
              ArgumentNode(
                name: NameNode(value: 'id'),
                value: VariableNode(name: NameNode(value: 'id')),
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
                  name: NameNode(value: 'device'),
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
                        name: NameNode(value: 'deviceName'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'platform'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'lastSeenAt'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'isRevoked'),
                        alias: null,
                        arguments: [],
                        directives: [],
                        selectionSet: null,
                      ),
                      FieldNode(
                        name: NameNode(value: 'createdAt'),
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

class Mutation$RevokeDevice$revokeDevice {
  Mutation$RevokeDevice$revokeDevice({
    required this.success,
    this.device,
    this.$__typename = 'RevokeDeviceResult',
  });

  factory Mutation$RevokeDevice$revokeDevice.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$success = json['success'];
    final l$device = json['device'];
    final l$$__typename = json['__typename'];
    return Mutation$RevokeDevice$revokeDevice(
      success: (l$success as bool),
      device: l$device == null
          ? null
          : Mutation$RevokeDevice$revokeDevice$device.fromJson(
              (l$device as Map<String, dynamic>),
            ),
      $__typename: (l$$__typename as String),
    );
  }

  final bool success;

  final Mutation$RevokeDevice$revokeDevice$device? device;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$success = success;
    _resultData['success'] = l$success;
    final l$device = device;
    _resultData['device'] = l$device?.toJson();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$success = success;
    final l$device = device;
    final l$$__typename = $__typename;
    return Object.hashAll([l$success, l$device, l$$__typename]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$RevokeDevice$revokeDevice ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$success = success;
    final lOther$success = other.success;
    if (l$success != lOther$success) {
      return false;
    }
    final l$device = device;
    final lOther$device = other.device;
    if (l$device != lOther$device) {
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

extension UtilityExtension$Mutation$RevokeDevice$revokeDevice
    on Mutation$RevokeDevice$revokeDevice {
  CopyWith$Mutation$RevokeDevice$revokeDevice<
          Mutation$RevokeDevice$revokeDevice>
      get copyWith =>
          CopyWith$Mutation$RevokeDevice$revokeDevice(this, (i) => i);
}

abstract class CopyWith$Mutation$RevokeDevice$revokeDevice<TRes> {
  factory CopyWith$Mutation$RevokeDevice$revokeDevice(
    Mutation$RevokeDevice$revokeDevice instance,
    TRes Function(Mutation$RevokeDevice$revokeDevice) then,
  ) = _CopyWithImpl$Mutation$RevokeDevice$revokeDevice;

  factory CopyWith$Mutation$RevokeDevice$revokeDevice.stub(TRes res) =
      _CopyWithStubImpl$Mutation$RevokeDevice$revokeDevice;

  TRes call({
    bool? success,
    Mutation$RevokeDevice$revokeDevice$device? device,
    String? $__typename,
  });
  CopyWith$Mutation$RevokeDevice$revokeDevice$device<TRes> get device;
}

class _CopyWithImpl$Mutation$RevokeDevice$revokeDevice<TRes>
    implements CopyWith$Mutation$RevokeDevice$revokeDevice<TRes> {
  _CopyWithImpl$Mutation$RevokeDevice$revokeDevice(this._instance, this._then);

  final Mutation$RevokeDevice$revokeDevice _instance;

  final TRes Function(Mutation$RevokeDevice$revokeDevice) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? success = _undefined,
    Object? device = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$RevokeDevice$revokeDevice(
          success: success == _undefined || success == null
              ? _instance.success
              : (success as bool),
          device: device == _undefined
              ? _instance.device
              : (device as Mutation$RevokeDevice$revokeDevice$device?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  CopyWith$Mutation$RevokeDevice$revokeDevice$device<TRes> get device {
    final local$device = _instance.device;
    return local$device == null
        ? CopyWith$Mutation$RevokeDevice$revokeDevice$device.stub(
            _then(_instance),
          )
        : CopyWith$Mutation$RevokeDevice$revokeDevice$device(
            local$device,
            (e) => call(device: e),
          );
  }
}

class _CopyWithStubImpl$Mutation$RevokeDevice$revokeDevice<TRes>
    implements CopyWith$Mutation$RevokeDevice$revokeDevice<TRes> {
  _CopyWithStubImpl$Mutation$RevokeDevice$revokeDevice(this._res);

  TRes _res;

  call({
    bool? success,
    Mutation$RevokeDevice$revokeDevice$device? device,
    String? $__typename,
  }) =>
      _res;

  CopyWith$Mutation$RevokeDevice$revokeDevice$device<TRes> get device =>
      CopyWith$Mutation$RevokeDevice$revokeDevice$device.stub(_res);
}

class Mutation$RevokeDevice$revokeDevice$device {
  Mutation$RevokeDevice$revokeDevice$device({
    required this.id,
    required this.deviceName,
    required this.platform,
    this.lastSeenAt,
    required this.isRevoked,
    required this.createdAt,
    this.$__typename = 'RemoteDevice',
  });

  factory Mutation$RevokeDevice$revokeDevice$device.fromJson(
    Map<String, dynamic> json,
  ) {
    final l$id = json['id'];
    final l$deviceName = json['deviceName'];
    final l$platform = json['platform'];
    final l$lastSeenAt = json['lastSeenAt'];
    final l$isRevoked = json['isRevoked'];
    final l$createdAt = json['createdAt'];
    final l$$__typename = json['__typename'];
    return Mutation$RevokeDevice$revokeDevice$device(
      id: (l$id as String),
      deviceName: (l$deviceName as String),
      platform: (l$platform as String),
      lastSeenAt: (l$lastSeenAt as String?),
      isRevoked: (l$isRevoked as bool),
      createdAt: (l$createdAt as String),
      $__typename: (l$$__typename as String),
    );
  }

  final String id;

  final String deviceName;

  final String platform;

  final String? lastSeenAt;

  final bool isRevoked;

  final String createdAt;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$id = id;
    _resultData['id'] = l$id;
    final l$deviceName = deviceName;
    _resultData['deviceName'] = l$deviceName;
    final l$platform = platform;
    _resultData['platform'] = l$platform;
    final l$lastSeenAt = lastSeenAt;
    _resultData['lastSeenAt'] = l$lastSeenAt;
    final l$isRevoked = isRevoked;
    _resultData['isRevoked'] = l$isRevoked;
    final l$createdAt = createdAt;
    _resultData['createdAt'] = l$createdAt;
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$id = id;
    final l$deviceName = deviceName;
    final l$platform = platform;
    final l$lastSeenAt = lastSeenAt;
    final l$isRevoked = isRevoked;
    final l$createdAt = createdAt;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$id,
      l$deviceName,
      l$platform,
      l$lastSeenAt,
      l$isRevoked,
      l$createdAt,
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Mutation$RevokeDevice$revokeDevice$device ||
        runtimeType != other.runtimeType) {
      return false;
    }
    final l$id = id;
    final lOther$id = other.id;
    if (l$id != lOther$id) {
      return false;
    }
    final l$deviceName = deviceName;
    final lOther$deviceName = other.deviceName;
    if (l$deviceName != lOther$deviceName) {
      return false;
    }
    final l$platform = platform;
    final lOther$platform = other.platform;
    if (l$platform != lOther$platform) {
      return false;
    }
    final l$lastSeenAt = lastSeenAt;
    final lOther$lastSeenAt = other.lastSeenAt;
    if (l$lastSeenAt != lOther$lastSeenAt) {
      return false;
    }
    final l$isRevoked = isRevoked;
    final lOther$isRevoked = other.isRevoked;
    if (l$isRevoked != lOther$isRevoked) {
      return false;
    }
    final l$createdAt = createdAt;
    final lOther$createdAt = other.createdAt;
    if (l$createdAt != lOther$createdAt) {
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

extension UtilityExtension$Mutation$RevokeDevice$revokeDevice$device
    on Mutation$RevokeDevice$revokeDevice$device {
  CopyWith$Mutation$RevokeDevice$revokeDevice$device<
          Mutation$RevokeDevice$revokeDevice$device>
      get copyWith =>
          CopyWith$Mutation$RevokeDevice$revokeDevice$device(this, (i) => i);
}

abstract class CopyWith$Mutation$RevokeDevice$revokeDevice$device<TRes> {
  factory CopyWith$Mutation$RevokeDevice$revokeDevice$device(
    Mutation$RevokeDevice$revokeDevice$device instance,
    TRes Function(Mutation$RevokeDevice$revokeDevice$device) then,
  ) = _CopyWithImpl$Mutation$RevokeDevice$revokeDevice$device;

  factory CopyWith$Mutation$RevokeDevice$revokeDevice$device.stub(TRes res) =
      _CopyWithStubImpl$Mutation$RevokeDevice$revokeDevice$device;

  TRes call({
    String? id,
    String? deviceName,
    String? platform,
    String? lastSeenAt,
    bool? isRevoked,
    String? createdAt,
    String? $__typename,
  });
}

class _CopyWithImpl$Mutation$RevokeDevice$revokeDevice$device<TRes>
    implements CopyWith$Mutation$RevokeDevice$revokeDevice$device<TRes> {
  _CopyWithImpl$Mutation$RevokeDevice$revokeDevice$device(
    this._instance,
    this._then,
  );

  final Mutation$RevokeDevice$revokeDevice$device _instance;

  final TRes Function(Mutation$RevokeDevice$revokeDevice$device) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? id = _undefined,
    Object? deviceName = _undefined,
    Object? platform = _undefined,
    Object? lastSeenAt = _undefined,
    Object? isRevoked = _undefined,
    Object? createdAt = _undefined,
    Object? $__typename = _undefined,
  }) =>
      _then(
        Mutation$RevokeDevice$revokeDevice$device(
          id: id == _undefined || id == null ? _instance.id : (id as String),
          deviceName: deviceName == _undefined || deviceName == null
              ? _instance.deviceName
              : (deviceName as String),
          platform: platform == _undefined || platform == null
              ? _instance.platform
              : (platform as String),
          lastSeenAt: lastSeenAt == _undefined
              ? _instance.lastSeenAt
              : (lastSeenAt as String?),
          isRevoked: isRevoked == _undefined || isRevoked == null
              ? _instance.isRevoked
              : (isRevoked as bool),
          createdAt: createdAt == _undefined || createdAt == null
              ? _instance.createdAt
              : (createdAt as String),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );
}

class _CopyWithStubImpl$Mutation$RevokeDevice$revokeDevice$device<TRes>
    implements CopyWith$Mutation$RevokeDevice$revokeDevice$device<TRes> {
  _CopyWithStubImpl$Mutation$RevokeDevice$revokeDevice$device(this._res);

  TRes _res;

  call({
    String? id,
    String? deviceName,
    String? platform,
    String? lastSeenAt,
    bool? isRevoked,
    String? createdAt,
    String? $__typename,
  }) =>
      _res;
}
