import 'package:gql/ast.dart';

class Query$DevicesList {
  Query$DevicesList({this.devices, this.$__typename = 'RootQueryType'});

  factory Query$DevicesList.fromJson(Map<String, dynamic> json) {
    final l$devices = json['devices'];
    final l$$__typename = json['__typename'];
    return Query$DevicesList(
      devices: (l$devices as List<dynamic>?)
          ?.map(
            (e) => e == null
                ? null
                : Query$DevicesList$devices.fromJson(
                    (e as Map<String, dynamic>),
                  ),
          )
          .toList(),
      $__typename: (l$$__typename as String),
    );
  }

  final List<Query$DevicesList$devices?>? devices;

  final String $__typename;

  Map<String, dynamic> toJson() {
    final _resultData = <String, dynamic>{};
    final l$devices = devices;
    _resultData['devices'] = l$devices?.map((e) => e?.toJson()).toList();
    final l$$__typename = $__typename;
    _resultData['__typename'] = l$$__typename;
    return _resultData;
  }

  @override
  int get hashCode {
    final l$devices = devices;
    final l$$__typename = $__typename;
    return Object.hashAll([
      l$devices == null ? null : Object.hashAll(l$devices.map((v) => v)),
      l$$__typename,
    ]);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Query$DevicesList || runtimeType != other.runtimeType) {
      return false;
    }
    final l$devices = devices;
    final lOther$devices = other.devices;
    if (l$devices != null && lOther$devices != null) {
      if (l$devices.length != lOther$devices.length) {
        return false;
      }
      for (int i = 0; i < l$devices.length; i++) {
        final l$devices$entry = l$devices[i];
        final lOther$devices$entry = lOther$devices[i];
        if (l$devices$entry != lOther$devices$entry) {
          return false;
        }
      }
    } else if (l$devices != lOther$devices) {
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

extension UtilityExtension$Query$DevicesList on Query$DevicesList {
  CopyWith$Query$DevicesList<Query$DevicesList> get copyWith =>
      CopyWith$Query$DevicesList(this, (i) => i);
}

abstract class CopyWith$Query$DevicesList<TRes> {
  factory CopyWith$Query$DevicesList(
    Query$DevicesList instance,
    TRes Function(Query$DevicesList) then,
  ) = _CopyWithImpl$Query$DevicesList;

  factory CopyWith$Query$DevicesList.stub(TRes res) =
      _CopyWithStubImpl$Query$DevicesList;

  TRes call({List<Query$DevicesList$devices?>? devices, String? $__typename});
  TRes devices(
    Iterable<Query$DevicesList$devices?>? Function(
      Iterable<CopyWith$Query$DevicesList$devices<Query$DevicesList$devices>?>?,
    ) _fn,
  );
}

class _CopyWithImpl$Query$DevicesList<TRes>
    implements CopyWith$Query$DevicesList<TRes> {
  _CopyWithImpl$Query$DevicesList(this._instance, this._then);

  final Query$DevicesList _instance;

  final TRes Function(Query$DevicesList) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? devices = _undefined, Object? $__typename = _undefined}) =>
      _then(
        Query$DevicesList(
          devices: devices == _undefined
              ? _instance.devices
              : (devices as List<Query$DevicesList$devices?>?),
          $__typename: $__typename == _undefined || $__typename == null
              ? _instance.$__typename
              : ($__typename as String),
        ),
      );

  TRes devices(
    Iterable<Query$DevicesList$devices?>? Function(
      Iterable<CopyWith$Query$DevicesList$devices<Query$DevicesList$devices>?>?,
    ) _fn,
  ) =>
      call(
        devices: _fn(
          _instance.devices?.map(
            (e) => e == null
                ? null
                : CopyWith$Query$DevicesList$devices(e, (i) => i),
          ),
        )?.toList(),
      );
}

class _CopyWithStubImpl$Query$DevicesList<TRes>
    implements CopyWith$Query$DevicesList<TRes> {
  _CopyWithStubImpl$Query$DevicesList(this._res);

  TRes _res;

  call({List<Query$DevicesList$devices?>? devices, String? $__typename}) =>
      _res;

  devices(_fn) => _res;
}

const documentNodeQueryDevicesList = DocumentNode(
  definitions: [
    OperationDefinitionNode(
      type: OperationType.query,
      name: NameNode(value: 'DevicesList'),
      variableDefinitions: [],
      directives: [],
      selectionSet: SelectionSetNode(
        selections: [
          FieldNode(
            name: NameNode(value: 'devices'),
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
  ],
);

class Query$DevicesList$devices {
  Query$DevicesList$devices({
    required this.id,
    required this.deviceName,
    required this.platform,
    this.lastSeenAt,
    required this.isRevoked,
    required this.createdAt,
    this.$__typename = 'RemoteDevice',
  });

  factory Query$DevicesList$devices.fromJson(Map<String, dynamic> json) {
    final l$id = json['id'];
    final l$deviceName = json['deviceName'];
    final l$platform = json['platform'];
    final l$lastSeenAt = json['lastSeenAt'];
    final l$isRevoked = json['isRevoked'];
    final l$createdAt = json['createdAt'];
    final l$$__typename = json['__typename'];
    return Query$DevicesList$devices(
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
    if (other is! Query$DevicesList$devices ||
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

extension UtilityExtension$Query$DevicesList$devices
    on Query$DevicesList$devices {
  CopyWith$Query$DevicesList$devices<Query$DevicesList$devices> get copyWith =>
      CopyWith$Query$DevicesList$devices(this, (i) => i);
}

abstract class CopyWith$Query$DevicesList$devices<TRes> {
  factory CopyWith$Query$DevicesList$devices(
    Query$DevicesList$devices instance,
    TRes Function(Query$DevicesList$devices) then,
  ) = _CopyWithImpl$Query$DevicesList$devices;

  factory CopyWith$Query$DevicesList$devices.stub(TRes res) =
      _CopyWithStubImpl$Query$DevicesList$devices;

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

class _CopyWithImpl$Query$DevicesList$devices<TRes>
    implements CopyWith$Query$DevicesList$devices<TRes> {
  _CopyWithImpl$Query$DevicesList$devices(this._instance, this._then);

  final Query$DevicesList$devices _instance;

  final TRes Function(Query$DevicesList$devices) _then;

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
        Query$DevicesList$devices(
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

class _CopyWithStubImpl$Query$DevicesList$devices<TRes>
    implements CopyWith$Query$DevicesList$devices<TRes> {
  _CopyWithStubImpl$Query$DevicesList$devices(this._res);

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
