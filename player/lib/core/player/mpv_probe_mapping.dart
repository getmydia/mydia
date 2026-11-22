import '../../domain/models/media_stream.dart';

/// What a headless mpv probe learned about one file.
class ProbeResult {
  final String? container;
  final double? durationSeconds;
  final int? bitrate;
  final List<MediaStream> streams;

  const ProbeResult({
    this.container,
    this.durationSeconds,
    this.bitrate,
    this.streams = const [],
  });

  Map<String, Object?> toMap() => {
    'container': container,
    'durationSeconds': durationSeconds,
    'bitrate': bitrate,
    'streams': streams.map(_streamToMap).toList(),
  };

  factory ProbeResult.fromMap(Map<dynamic, dynamic> map) {
    final raw = map['streams'];
    return ProbeResult(
      container: _str(map['container']),
      durationSeconds: _double(map['durationSeconds']),
      bitrate: _int(map['bitrate']),
      streams: raw is List
          ? raw.whereType<Map<dynamic, dynamic>>().map(_streamFromMap).toList()
          : const [],
    );
  }

  MediaStream? get _defaultVideo {
    final videos = streams
        .where((s) => s.type == MediaStreamType.video)
        .toList();
    if (videos.isEmpty) return null;
    return videos.firstWhere((s) => s.isDefault, orElse: () => videos.first);
  }

  /// `2160p`, `1080p`, ... from the default video stream. Mirrors the
  /// server's rule: cropped scope encodes (1920x800) keep the source width, so
  /// when the height is not near a standard tier the tier comes from the width.
  String? get resolution {
    final video = _defaultVideo;
    final height = video?.height;
    if (height == null || height <= 0) return null;
    final effective = _effectiveHeight(video?.width, height);
    if (effective >= 2000) return '2160p';
    if (effective >= 1400) return '1440p';
    if (effective >= 1000) return '1080p';
    if (effective >= 700) return '720p';
    if (effective >= 400) return '480p';
    return '${effective}p';
  }

  String? get videoCodec => _defaultVideo?.codec;
}

const _standardHeights = [2160, 1440, 1080, 720, 480, 360];
const _heightTolerance = 24;

int _effectiveHeight(int? width, int height) {
  if (width == null || width <= height) return height;
  if (_standardHeights.any((h) => (height - h).abs() <= _heightTolerance)) {
    return height;
  }
  if (width >= 3800) return 2160;
  if (width >= 2500) return 1440;
  if (width >= 1900) return 1080;
  if (width >= 1200) return 720;
  return height;
}

/// Maps the values mpv reports (`file-format`, `duration`, `file-size`,
/// `track-list`, `video-params`) to a [ProbeResult]. Values may be numbers or
/// strings; anything unparseable becomes null.
ProbeResult mapMpvProbe({
  required String? fileFormat,
  required double? duration,
  required int? fileSize,
  required List<Object?> trackList,
  required Map<String, Object?>? videoParams,
}) {
  final tracks = <Map<dynamic, dynamic>>[
    for (final t in trackList)
      if (t is Map &&
          !_bool(t['external']) &&
          !_bool(t['albumart']) &&
          !_bool(t['image']))
        t,
  ];

  // The default video track gets the colour fields from video-params.
  final videoTracks = tracks.where((t) => t['type'] == 'video').toList();
  Map<dynamic, dynamic>? colourTrack;
  if (videoTracks.isNotEmpty) {
    colourTrack = videoTracks.firstWhere(
      (t) => _bool(t['default']),
      orElse: () => videoTracks.first,
    );
  }

  final streams = <MediaStream>[];
  for (final t in tracks) {
    final type = switch (t['type']) {
      'video' => MediaStreamType.video,
      'audio' => MediaStreamType.audio,
      'sub' => MediaStreamType.subtitle,
      _ => null,
    };
    if (type == null) continue;
    streams.add(
      _mapTrack(t, type, identical(t, colourTrack) ? videoParams : null),
    );
  }

  // File size over duration is the real overall rate. FFmpeg often leaves
  // demux-bitrate empty for video, so the track sum is only a fallback.
  int? bitrate;
  if (fileSize != null && fileSize > 0 && duration != null && duration > 0) {
    bitrate = fileSize * 8 ~/ duration;
  } else {
    final trackBitrates = tracks.map((t) => _int(t['demux-bitrate'])).nonNulls;
    if (trackBitrates.isNotEmpty) {
      bitrate = trackBitrates.fold<int>(0, (a, b) => a + b);
    }
  }

  final format = fileFormat?.split(',').first.trim();
  return ProbeResult(
    container: (format == null || format.isEmpty) ? null : format,
    durationSeconds: duration,
    bitrate: bitrate,
    streams: streams,
  );
}

MediaStream _mapTrack(
  Map<dynamic, dynamic> t,
  MediaStreamType type,
  Map<String, Object?>? params,
) {
  final title = _str(t['title']);
  final pixelFormat = params == null ? null : _str(params['pixelformat']);
  return MediaStream(
    index: _int(t['src-id']),
    type: type,
    codec: _str(t['codec']),
    codecLong: _str(t['decoder-desc']) ?? _str(t['codec-desc']),
    profile: _str(t['codec-profile']),
    language: _str(t['lang']),
    title: title,
    bitrate: _int(t['demux-bitrate']),
    isDefault: _bool(t['default']),
    isForced: _bool(t['forced']),
    isHearingImpaired: _bool(t['hearing-impaired']),
    isCommentary: title != null && title.toLowerCase().contains('commentary'),
    width: _int(t['demux-w']),
    height: _int(t['demux-h']),
    frameRate: _double(t['demux-fps']),
    pixelFormat: pixelFormat,
    bitDepth: pixelFormat == null ? null : _bitDepth(pixelFormat),
    colorSpace: params == null ? null : _str(params['colormatrix']),
    colorTransfer: params == null ? null : _str(params['gamma']),
    colorPrimaries: params == null ? null : _str(params['primaries']),
    dolbyVisionProfile: _int(t['dolby-vision-profile']),
    channels: _int(t['demux-channel-count']),
    channelLayout: _str(t['demux-channels']),
    sampleRate: _int(t['demux-samplerate']),
  );
}

int _bitDepth(String pixelFormat) {
  final f = pixelFormat.toLowerCase();
  // yuv420p10, yuv444p12le, p010, p012. Not nv12 or yuv410p, which are 8-bit.
  final m = RegExp(r'p0?(10|12)(le|be)?$').firstMatch(f);
  return m == null ? 8 : int.parse(m.group(1)!);
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = v.toString();
  return s.isEmpty ? null : s;
}

int? _int(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) {
    return int.tryParse(v) ?? double.tryParse(v)?.toInt();
  }
  return null;
}

double? _double(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

bool _bool(Object? v) => v == true || v == 'yes' || v == 'true';

Map<String, Object?> _streamToMap(MediaStream s) => {
  'index': s.index,
  'type': s.type.name,
  'codec': s.codec,
  'codecLong': s.codecLong,
  'profile': s.profile,
  'level': s.level,
  'language': s.language,
  'title': s.title,
  'bitrate': s.bitrate,
  'isDefault': s.isDefault,
  'isForced': s.isForced,
  'isHearingImpaired': s.isHearingImpaired,
  'isCommentary': s.isCommentary,
  'width': s.width,
  'height': s.height,
  'frameRate': s.frameRate,
  'pixelFormat': s.pixelFormat,
  'bitDepth': s.bitDepth,
  'colorSpace': s.colorSpace,
  'colorTransfer': s.colorTransfer,
  'colorPrimaries': s.colorPrimaries,
  'dolbyVisionProfile': s.dolbyVisionProfile,
  'aspectRatio': s.aspectRatio,
  'channels': s.channels,
  'channelLayout': s.channelLayout,
  'sampleRate': s.sampleRate,
};

MediaStream _streamFromMap(Map<dynamic, dynamic> m) => MediaStream(
  index: _int(m['index']),
  type: MediaStreamType.values.firstWhere(
    (t) => t.name == m['type'],
    orElse: () => MediaStreamType.video,
  ),
  codec: _str(m['codec']),
  codecLong: _str(m['codecLong']),
  profile: _str(m['profile']),
  level: _int(m['level']),
  language: _str(m['language']),
  title: _str(m['title']),
  bitrate: _int(m['bitrate']),
  isDefault: _bool(m['isDefault']),
  isForced: _bool(m['isForced']),
  isHearingImpaired: _bool(m['isHearingImpaired']),
  isCommentary: _bool(m['isCommentary']),
  width: _int(m['width']),
  height: _int(m['height']),
  frameRate: _double(m['frameRate']),
  pixelFormat: _str(m['pixelFormat']),
  bitDepth: _int(m['bitDepth']),
  colorSpace: _str(m['colorSpace']),
  colorTransfer: _str(m['colorTransfer']),
  colorPrimaries: _str(m['colorPrimaries']),
  dolbyVisionProfile: _int(m['dolbyVisionProfile']),
  aspectRatio: _str(m['aspectRatio']),
  channels: _int(m['channels']),
  channelLayout: _str(m['channelLayout']),
  sampleRate: _int(m['sampleRate']),
);
