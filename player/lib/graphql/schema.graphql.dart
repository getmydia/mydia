class Input$SortInput {
  factory Input$SortInput({
    Enum$SortField? field,
    Enum$SortDirection? direction,
  }) =>
      Input$SortInput._({
        if (field != null) r'field': field,
        if (direction != null) r'direction': direction,
      });

  Input$SortInput._(this._$data);

  factory Input$SortInput.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    if (data.containsKey('field')) {
      final l$field = data['field'];
      result$data['field'] =
          l$field == null ? null : fromJson$Enum$SortField((l$field as String));
    }
    if (data.containsKey('direction')) {
      final l$direction = data['direction'];
      result$data['direction'] = l$direction == null
          ? null
          : fromJson$Enum$SortDirection((l$direction as String));
    }
    return Input$SortInput._(result$data);
  }

  Map<String, dynamic> _$data;

  Enum$SortField? get field => (_$data['field'] as Enum$SortField?);

  Enum$SortDirection? get direction =>
      (_$data['direction'] as Enum$SortDirection?);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    if (_$data.containsKey('field')) {
      final l$field = field;
      result$data['field'] =
          l$field == null ? null : toJson$Enum$SortField(l$field);
    }
    if (_$data.containsKey('direction')) {
      final l$direction = direction;
      result$data['direction'] =
          l$direction == null ? null : toJson$Enum$SortDirection(l$direction);
    }
    return result$data;
  }

  CopyWith$Input$SortInput<Input$SortInput> get copyWith =>
      CopyWith$Input$SortInput(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Input$SortInput || runtimeType != other.runtimeType) {
      return false;
    }
    final l$field = field;
    final lOther$field = other.field;
    if (_$data.containsKey('field') != other._$data.containsKey('field')) {
      return false;
    }
    if (l$field != lOther$field) {
      return false;
    }
    final l$direction = direction;
    final lOther$direction = other.direction;
    if (_$data.containsKey('direction') !=
        other._$data.containsKey('direction')) {
      return false;
    }
    if (l$direction != lOther$direction) {
      return false;
    }
    return true;
  }

  @override
  int get hashCode {
    final l$field = field;
    final l$direction = direction;
    return Object.hashAll([
      _$data.containsKey('field') ? l$field : const {},
      _$data.containsKey('direction') ? l$direction : const {},
    ]);
  }
}

abstract class CopyWith$Input$SortInput<TRes> {
  factory CopyWith$Input$SortInput(
    Input$SortInput instance,
    TRes Function(Input$SortInput) then,
  ) = _CopyWithImpl$Input$SortInput;

  factory CopyWith$Input$SortInput.stub(TRes res) =
      _CopyWithStubImpl$Input$SortInput;

  TRes call({Enum$SortField? field, Enum$SortDirection? direction});
}

class _CopyWithImpl$Input$SortInput<TRes>
    implements CopyWith$Input$SortInput<TRes> {
  _CopyWithImpl$Input$SortInput(this._instance, this._then);

  final Input$SortInput _instance;

  final TRes Function(Input$SortInput) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({Object? field = _undefined, Object? direction = _undefined}) =>
      _then(
        Input$SortInput._({
          ..._instance._$data,
          if (field != _undefined) 'field': (field as Enum$SortField?),
          if (direction != _undefined)
            'direction': (direction as Enum$SortDirection?),
        }),
      );
}

class _CopyWithStubImpl$Input$SortInput<TRes>
    implements CopyWith$Input$SortInput<TRes> {
  _CopyWithStubImpl$Input$SortInput(this._res);

  TRes _res;

  call({Enum$SortField? field, Enum$SortDirection? direction}) => _res;
}

class Input$LoginInput {
  factory Input$LoginInput({
    required String username,
    required String password,
    required String deviceId,
    required String deviceName,
    required String platform,
  }) =>
      Input$LoginInput._({
        r'username': username,
        r'password': password,
        r'deviceId': deviceId,
        r'deviceName': deviceName,
        r'platform': platform,
      });

  Input$LoginInput._(this._$data);

  factory Input$LoginInput.fromJson(Map<String, dynamic> data) {
    final result$data = <String, dynamic>{};
    final l$username = data['username'];
    result$data['username'] = (l$username as String);
    final l$password = data['password'];
    result$data['password'] = (l$password as String);
    final l$deviceId = data['deviceId'];
    result$data['deviceId'] = (l$deviceId as String);
    final l$deviceName = data['deviceName'];
    result$data['deviceName'] = (l$deviceName as String);
    final l$platform = data['platform'];
    result$data['platform'] = (l$platform as String);
    return Input$LoginInput._(result$data);
  }

  Map<String, dynamic> _$data;

  String get username => (_$data['username'] as String);

  String get password => (_$data['password'] as String);

  String get deviceId => (_$data['deviceId'] as String);

  String get deviceName => (_$data['deviceName'] as String);

  String get platform => (_$data['platform'] as String);

  Map<String, dynamic> toJson() {
    final result$data = <String, dynamic>{};
    final l$username = username;
    result$data['username'] = l$username;
    final l$password = password;
    result$data['password'] = l$password;
    final l$deviceId = deviceId;
    result$data['deviceId'] = l$deviceId;
    final l$deviceName = deviceName;
    result$data['deviceName'] = l$deviceName;
    final l$platform = platform;
    result$data['platform'] = l$platform;
    return result$data;
  }

  CopyWith$Input$LoginInput<Input$LoginInput> get copyWith =>
      CopyWith$Input$LoginInput(this, (i) => i);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! Input$LoginInput || runtimeType != other.runtimeType) {
      return false;
    }
    final l$username = username;
    final lOther$username = other.username;
    if (l$username != lOther$username) {
      return false;
    }
    final l$password = password;
    final lOther$password = other.password;
    if (l$password != lOther$password) {
      return false;
    }
    final l$deviceId = deviceId;
    final lOther$deviceId = other.deviceId;
    if (l$deviceId != lOther$deviceId) {
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
    return true;
  }

  @override
  int get hashCode {
    final l$username = username;
    final l$password = password;
    final l$deviceId = deviceId;
    final l$deviceName = deviceName;
    final l$platform = platform;
    return Object.hashAll([
      l$username,
      l$password,
      l$deviceId,
      l$deviceName,
      l$platform,
    ]);
  }
}

abstract class CopyWith$Input$LoginInput<TRes> {
  factory CopyWith$Input$LoginInput(
    Input$LoginInput instance,
    TRes Function(Input$LoginInput) then,
  ) = _CopyWithImpl$Input$LoginInput;

  factory CopyWith$Input$LoginInput.stub(TRes res) =
      _CopyWithStubImpl$Input$LoginInput;

  TRes call({
    String? username,
    String? password,
    String? deviceId,
    String? deviceName,
    String? platform,
  });
}

class _CopyWithImpl$Input$LoginInput<TRes>
    implements CopyWith$Input$LoginInput<TRes> {
  _CopyWithImpl$Input$LoginInput(this._instance, this._then);

  final Input$LoginInput _instance;

  final TRes Function(Input$LoginInput) _then;

  static const _undefined = <dynamic, dynamic>{};

  TRes call({
    Object? username = _undefined,
    Object? password = _undefined,
    Object? deviceId = _undefined,
    Object? deviceName = _undefined,
    Object? platform = _undefined,
  }) =>
      _then(
        Input$LoginInput._({
          ..._instance._$data,
          if (username != _undefined && username != null)
            'username': (username as String),
          if (password != _undefined && password != null)
            'password': (password as String),
          if (deviceId != _undefined && deviceId != null)
            'deviceId': (deviceId as String),
          if (deviceName != _undefined && deviceName != null)
            'deviceName': (deviceName as String),
          if (platform != _undefined && platform != null)
            'platform': (platform as String),
        }),
      );
}

class _CopyWithStubImpl$Input$LoginInput<TRes>
    implements CopyWith$Input$LoginInput<TRes> {
  _CopyWithStubImpl$Input$LoginInput(this._res);

  TRes _res;

  call({
    String? username,
    String? password,
    String? deviceId,
    String? deviceName,
    String? platform,
  }) =>
      _res;
}

enum Enum$DeviceEventType {
  CONNECTED,
  DISCONNECTED,
  REVOKED,
  DELETED,
  $unknown;

  factory Enum$DeviceEventType.fromJson(String value) =>
      fromJson$Enum$DeviceEventType(value);

  String toJson() => toJson$Enum$DeviceEventType(this);
}

String toJson$Enum$DeviceEventType(Enum$DeviceEventType e) {
  switch (e) {
    case Enum$DeviceEventType.CONNECTED:
      return r'CONNECTED';
    case Enum$DeviceEventType.DISCONNECTED:
      return r'DISCONNECTED';
    case Enum$DeviceEventType.REVOKED:
      return r'REVOKED';
    case Enum$DeviceEventType.DELETED:
      return r'DELETED';
    case Enum$DeviceEventType.$unknown:
      return r'$unknown';
  }
}

Enum$DeviceEventType fromJson$Enum$DeviceEventType(String value) {
  switch (value) {
    case r'CONNECTED':
      return Enum$DeviceEventType.CONNECTED;
    case r'DISCONNECTED':
      return Enum$DeviceEventType.DISCONNECTED;
    case r'REVOKED':
      return Enum$DeviceEventType.REVOKED;
    case r'DELETED':
      return Enum$DeviceEventType.DELETED;
    default:
      return Enum$DeviceEventType.$unknown;
  }
}

enum Enum$MediaType {
  MOVIE,
  TV_SHOW,
  EPISODE,
  $unknown;

  factory Enum$MediaType.fromJson(String value) =>
      fromJson$Enum$MediaType(value);

  String toJson() => toJson$Enum$MediaType(this);
}

String toJson$Enum$MediaType(Enum$MediaType e) {
  switch (e) {
    case Enum$MediaType.MOVIE:
      return r'MOVIE';
    case Enum$MediaType.TV_SHOW:
      return r'TV_SHOW';
    case Enum$MediaType.EPISODE:
      return r'EPISODE';
    case Enum$MediaType.$unknown:
      return r'$unknown';
  }
}

Enum$MediaType fromJson$Enum$MediaType(String value) {
  switch (value) {
    case r'MOVIE':
      return Enum$MediaType.MOVIE;
    case r'TV_SHOW':
      return Enum$MediaType.TV_SHOW;
    case r'EPISODE':
      return Enum$MediaType.EPISODE;
    default:
      return Enum$MediaType.$unknown;
  }
}

enum Enum$LibraryType {
  MOVIES,
  SERIES,
  MIXED,
  MUSIC,
  BOOKS,
  ADULT,
  $unknown;

  factory Enum$LibraryType.fromJson(String value) =>
      fromJson$Enum$LibraryType(value);

  String toJson() => toJson$Enum$LibraryType(this);
}

String toJson$Enum$LibraryType(Enum$LibraryType e) {
  switch (e) {
    case Enum$LibraryType.MOVIES:
      return r'MOVIES';
    case Enum$LibraryType.SERIES:
      return r'SERIES';
    case Enum$LibraryType.MIXED:
      return r'MIXED';
    case Enum$LibraryType.MUSIC:
      return r'MUSIC';
    case Enum$LibraryType.BOOKS:
      return r'BOOKS';
    case Enum$LibraryType.ADULT:
      return r'ADULT';
    case Enum$LibraryType.$unknown:
      return r'$unknown';
  }
}

Enum$LibraryType fromJson$Enum$LibraryType(String value) {
  switch (value) {
    case r'MOVIES':
      return Enum$LibraryType.MOVIES;
    case r'SERIES':
      return Enum$LibraryType.SERIES;
    case r'MIXED':
      return Enum$LibraryType.MIXED;
    case r'MUSIC':
      return Enum$LibraryType.MUSIC;
    case r'BOOKS':
      return Enum$LibraryType.BOOKS;
    case r'ADULT':
      return Enum$LibraryType.ADULT;
    default:
      return Enum$LibraryType.$unknown;
  }
}

enum Enum$SortField {
  TITLE,
  ADDED_AT,
  YEAR,
  RATING,
  $unknown;

  factory Enum$SortField.fromJson(String value) =>
      fromJson$Enum$SortField(value);

  String toJson() => toJson$Enum$SortField(this);
}

String toJson$Enum$SortField(Enum$SortField e) {
  switch (e) {
    case Enum$SortField.TITLE:
      return r'TITLE';
    case Enum$SortField.ADDED_AT:
      return r'ADDED_AT';
    case Enum$SortField.YEAR:
      return r'YEAR';
    case Enum$SortField.RATING:
      return r'RATING';
    case Enum$SortField.$unknown:
      return r'$unknown';
  }
}

Enum$SortField fromJson$Enum$SortField(String value) {
  switch (value) {
    case r'TITLE':
      return Enum$SortField.TITLE;
    case r'ADDED_AT':
      return Enum$SortField.ADDED_AT;
    case r'YEAR':
      return Enum$SortField.YEAR;
    case r'RATING':
      return Enum$SortField.RATING;
    default:
      return Enum$SortField.$unknown;
  }
}

enum Enum$SortDirection {
  ASC,
  DESC,
  $unknown;

  factory Enum$SortDirection.fromJson(String value) =>
      fromJson$Enum$SortDirection(value);

  String toJson() => toJson$Enum$SortDirection(this);
}

String toJson$Enum$SortDirection(Enum$SortDirection e) {
  switch (e) {
    case Enum$SortDirection.ASC:
      return r'ASC';
    case Enum$SortDirection.DESC:
      return r'DESC';
    case Enum$SortDirection.$unknown:
      return r'$unknown';
  }
}

Enum$SortDirection fromJson$Enum$SortDirection(String value) {
  switch (value) {
    case r'ASC':
      return Enum$SortDirection.ASC;
    case r'DESC':
      return Enum$SortDirection.DESC;
    default:
      return Enum$SortDirection.$unknown;
  }
}

enum Enum$MediaCategory {
  MOVIE,
  ANIME_MOVIE,
  CARTOON_MOVIE,
  TV_SHOW,
  ANIME_SERIES,
  CARTOON_SERIES,
  $unknown;

  factory Enum$MediaCategory.fromJson(String value) =>
      fromJson$Enum$MediaCategory(value);

  String toJson() => toJson$Enum$MediaCategory(this);
}

String toJson$Enum$MediaCategory(Enum$MediaCategory e) {
  switch (e) {
    case Enum$MediaCategory.MOVIE:
      return r'MOVIE';
    case Enum$MediaCategory.ANIME_MOVIE:
      return r'ANIME_MOVIE';
    case Enum$MediaCategory.CARTOON_MOVIE:
      return r'CARTOON_MOVIE';
    case Enum$MediaCategory.TV_SHOW:
      return r'TV_SHOW';
    case Enum$MediaCategory.ANIME_SERIES:
      return r'ANIME_SERIES';
    case Enum$MediaCategory.CARTOON_SERIES:
      return r'CARTOON_SERIES';
    case Enum$MediaCategory.$unknown:
      return r'$unknown';
  }
}

Enum$MediaCategory fromJson$Enum$MediaCategory(String value) {
  switch (value) {
    case r'MOVIE':
      return Enum$MediaCategory.MOVIE;
    case r'ANIME_MOVIE':
      return Enum$MediaCategory.ANIME_MOVIE;
    case r'CARTOON_MOVIE':
      return Enum$MediaCategory.CARTOON_MOVIE;
    case r'TV_SHOW':
      return Enum$MediaCategory.TV_SHOW;
    case r'ANIME_SERIES':
      return Enum$MediaCategory.ANIME_SERIES;
    case r'CARTOON_SERIES':
      return Enum$MediaCategory.CARTOON_SERIES;
    default:
      return Enum$MediaCategory.$unknown;
  }
}

enum Enum$SubtitleFormat {
  SRT,
  VTT,
  ASS,
  SSA,
  PGS,
  VOBSUB,
  UNKNOWN,
  $unknown;

  factory Enum$SubtitleFormat.fromJson(String value) =>
      fromJson$Enum$SubtitleFormat(value);

  String toJson() => toJson$Enum$SubtitleFormat(this);
}

String toJson$Enum$SubtitleFormat(Enum$SubtitleFormat e) {
  switch (e) {
    case Enum$SubtitleFormat.SRT:
      return r'SRT';
    case Enum$SubtitleFormat.VTT:
      return r'VTT';
    case Enum$SubtitleFormat.ASS:
      return r'ASS';
    case Enum$SubtitleFormat.SSA:
      return r'SSA';
    case Enum$SubtitleFormat.PGS:
      return r'PGS';
    case Enum$SubtitleFormat.VOBSUB:
      return r'VOBSUB';
    case Enum$SubtitleFormat.UNKNOWN:
      return r'UNKNOWN';
    case Enum$SubtitleFormat.$unknown:
      return r'$unknown';
  }
}

Enum$SubtitleFormat fromJson$Enum$SubtitleFormat(String value) {
  switch (value) {
    case r'SRT':
      return Enum$SubtitleFormat.SRT;
    case r'VTT':
      return Enum$SubtitleFormat.VTT;
    case r'ASS':
      return Enum$SubtitleFormat.ASS;
    case r'SSA':
      return Enum$SubtitleFormat.SSA;
    case r'PGS':
      return Enum$SubtitleFormat.PGS;
    case r'VOBSUB':
      return Enum$SubtitleFormat.VOBSUB;
    case r'UNKNOWN':
      return Enum$SubtitleFormat.UNKNOWN;
    default:
      return Enum$SubtitleFormat.$unknown;
  }
}

enum Enum$StreamingStrategy {
  HLS_COPY,
  TRANSCODE,
  $unknown;

  factory Enum$StreamingStrategy.fromJson(String value) =>
      fromJson$Enum$StreamingStrategy(value);

  String toJson() => toJson$Enum$StreamingStrategy(this);
}

String toJson$Enum$StreamingStrategy(Enum$StreamingStrategy e) {
  switch (e) {
    case Enum$StreamingStrategy.HLS_COPY:
      return r'HLS_COPY';
    case Enum$StreamingStrategy.TRANSCODE:
      return r'TRANSCODE';
    case Enum$StreamingStrategy.$unknown:
      return r'$unknown';
  }
}

Enum$StreamingStrategy fromJson$Enum$StreamingStrategy(String value) {
  switch (value) {
    case r'HLS_COPY':
      return Enum$StreamingStrategy.HLS_COPY;
    case r'TRANSCODE':
      return Enum$StreamingStrategy.TRANSCODE;
    default:
      return Enum$StreamingStrategy.$unknown;
  }
}

enum Enum$StreamingCandidateStrategy {
  DIRECT_PLAY,
  REMUX,
  HLS_COPY,
  TRANSCODE,
  $unknown;

  factory Enum$StreamingCandidateStrategy.fromJson(String value) =>
      fromJson$Enum$StreamingCandidateStrategy(value);

  String toJson() => toJson$Enum$StreamingCandidateStrategy(this);
}

String toJson$Enum$StreamingCandidateStrategy(
  Enum$StreamingCandidateStrategy e,
) {
  switch (e) {
    case Enum$StreamingCandidateStrategy.DIRECT_PLAY:
      return r'DIRECT_PLAY';
    case Enum$StreamingCandidateStrategy.REMUX:
      return r'REMUX';
    case Enum$StreamingCandidateStrategy.HLS_COPY:
      return r'HLS_COPY';
    case Enum$StreamingCandidateStrategy.TRANSCODE:
      return r'TRANSCODE';
    case Enum$StreamingCandidateStrategy.$unknown:
      return r'$unknown';
  }
}

Enum$StreamingCandidateStrategy fromJson$Enum$StreamingCandidateStrategy(
  String value,
) {
  switch (value) {
    case r'DIRECT_PLAY':
      return Enum$StreamingCandidateStrategy.DIRECT_PLAY;
    case r'REMUX':
      return Enum$StreamingCandidateStrategy.REMUX;
    case r'HLS_COPY':
      return Enum$StreamingCandidateStrategy.HLS_COPY;
    case r'TRANSCODE':
      return Enum$StreamingCandidateStrategy.TRANSCODE;
    default:
      return Enum$StreamingCandidateStrategy.$unknown;
  }
}

enum Enum$__TypeKind {
  SCALAR,
  OBJECT,
  INTERFACE,
  UNION,
  ENUM,
  INPUT_OBJECT,
  LIST,
  NON_NULL,
  $unknown;

  factory Enum$__TypeKind.fromJson(String value) =>
      fromJson$Enum$__TypeKind(value);

  String toJson() => toJson$Enum$__TypeKind(this);
}

String toJson$Enum$__TypeKind(Enum$__TypeKind e) {
  switch (e) {
    case Enum$__TypeKind.SCALAR:
      return r'SCALAR';
    case Enum$__TypeKind.OBJECT:
      return r'OBJECT';
    case Enum$__TypeKind.INTERFACE:
      return r'INTERFACE';
    case Enum$__TypeKind.UNION:
      return r'UNION';
    case Enum$__TypeKind.ENUM:
      return r'ENUM';
    case Enum$__TypeKind.INPUT_OBJECT:
      return r'INPUT_OBJECT';
    case Enum$__TypeKind.LIST:
      return r'LIST';
    case Enum$__TypeKind.NON_NULL:
      return r'NON_NULL';
    case Enum$__TypeKind.$unknown:
      return r'$unknown';
  }
}

Enum$__TypeKind fromJson$Enum$__TypeKind(String value) {
  switch (value) {
    case r'SCALAR':
      return Enum$__TypeKind.SCALAR;
    case r'OBJECT':
      return Enum$__TypeKind.OBJECT;
    case r'INTERFACE':
      return Enum$__TypeKind.INTERFACE;
    case r'UNION':
      return Enum$__TypeKind.UNION;
    case r'ENUM':
      return Enum$__TypeKind.ENUM;
    case r'INPUT_OBJECT':
      return Enum$__TypeKind.INPUT_OBJECT;
    case r'LIST':
      return Enum$__TypeKind.LIST;
    case r'NON_NULL':
      return Enum$__TypeKind.NON_NULL;
    default:
      return Enum$__TypeKind.$unknown;
  }
}

enum Enum$__DirectiveLocation {
  QUERY,
  MUTATION,
  SUBSCRIPTION,
  FIELD,
  FRAGMENT_DEFINITION,
  FRAGMENT_SPREAD,
  INLINE_FRAGMENT,
  VARIABLE_DEFINITION,
  SCHEMA,
  SCALAR,
  OBJECT,
  FIELD_DEFINITION,
  ARGUMENT_DEFINITION,
  INTERFACE,
  UNION,
  ENUM,
  ENUM_VALUE,
  INPUT_OBJECT,
  INPUT_FIELD_DEFINITION,
  $unknown;

  factory Enum$__DirectiveLocation.fromJson(String value) =>
      fromJson$Enum$__DirectiveLocation(value);

  String toJson() => toJson$Enum$__DirectiveLocation(this);
}

String toJson$Enum$__DirectiveLocation(Enum$__DirectiveLocation e) {
  switch (e) {
    case Enum$__DirectiveLocation.QUERY:
      return r'QUERY';
    case Enum$__DirectiveLocation.MUTATION:
      return r'MUTATION';
    case Enum$__DirectiveLocation.SUBSCRIPTION:
      return r'SUBSCRIPTION';
    case Enum$__DirectiveLocation.FIELD:
      return r'FIELD';
    case Enum$__DirectiveLocation.FRAGMENT_DEFINITION:
      return r'FRAGMENT_DEFINITION';
    case Enum$__DirectiveLocation.FRAGMENT_SPREAD:
      return r'FRAGMENT_SPREAD';
    case Enum$__DirectiveLocation.INLINE_FRAGMENT:
      return r'INLINE_FRAGMENT';
    case Enum$__DirectiveLocation.VARIABLE_DEFINITION:
      return r'VARIABLE_DEFINITION';
    case Enum$__DirectiveLocation.SCHEMA:
      return r'SCHEMA';
    case Enum$__DirectiveLocation.SCALAR:
      return r'SCALAR';
    case Enum$__DirectiveLocation.OBJECT:
      return r'OBJECT';
    case Enum$__DirectiveLocation.FIELD_DEFINITION:
      return r'FIELD_DEFINITION';
    case Enum$__DirectiveLocation.ARGUMENT_DEFINITION:
      return r'ARGUMENT_DEFINITION';
    case Enum$__DirectiveLocation.INTERFACE:
      return r'INTERFACE';
    case Enum$__DirectiveLocation.UNION:
      return r'UNION';
    case Enum$__DirectiveLocation.ENUM:
      return r'ENUM';
    case Enum$__DirectiveLocation.ENUM_VALUE:
      return r'ENUM_VALUE';
    case Enum$__DirectiveLocation.INPUT_OBJECT:
      return r'INPUT_OBJECT';
    case Enum$__DirectiveLocation.INPUT_FIELD_DEFINITION:
      return r'INPUT_FIELD_DEFINITION';
    case Enum$__DirectiveLocation.$unknown:
      return r'$unknown';
  }
}

Enum$__DirectiveLocation fromJson$Enum$__DirectiveLocation(String value) {
  switch (value) {
    case r'QUERY':
      return Enum$__DirectiveLocation.QUERY;
    case r'MUTATION':
      return Enum$__DirectiveLocation.MUTATION;
    case r'SUBSCRIPTION':
      return Enum$__DirectiveLocation.SUBSCRIPTION;
    case r'FIELD':
      return Enum$__DirectiveLocation.FIELD;
    case r'FRAGMENT_DEFINITION':
      return Enum$__DirectiveLocation.FRAGMENT_DEFINITION;
    case r'FRAGMENT_SPREAD':
      return Enum$__DirectiveLocation.FRAGMENT_SPREAD;
    case r'INLINE_FRAGMENT':
      return Enum$__DirectiveLocation.INLINE_FRAGMENT;
    case r'VARIABLE_DEFINITION':
      return Enum$__DirectiveLocation.VARIABLE_DEFINITION;
    case r'SCHEMA':
      return Enum$__DirectiveLocation.SCHEMA;
    case r'SCALAR':
      return Enum$__DirectiveLocation.SCALAR;
    case r'OBJECT':
      return Enum$__DirectiveLocation.OBJECT;
    case r'FIELD_DEFINITION':
      return Enum$__DirectiveLocation.FIELD_DEFINITION;
    case r'ARGUMENT_DEFINITION':
      return Enum$__DirectiveLocation.ARGUMENT_DEFINITION;
    case r'INTERFACE':
      return Enum$__DirectiveLocation.INTERFACE;
    case r'UNION':
      return Enum$__DirectiveLocation.UNION;
    case r'ENUM':
      return Enum$__DirectiveLocation.ENUM;
    case r'ENUM_VALUE':
      return Enum$__DirectiveLocation.ENUM_VALUE;
    case r'INPUT_OBJECT':
      return Enum$__DirectiveLocation.INPUT_OBJECT;
    case r'INPUT_FIELD_DEFINITION':
      return Enum$__DirectiveLocation.INPUT_FIELD_DEFINITION;
    default:
      return Enum$__DirectiveLocation.$unknown;
  }
}

const possibleTypesMap = <String, Set<String>>{
  'Node': {'Movie', 'TvShow', 'Season', 'Episode', 'LibraryPath'},
};
