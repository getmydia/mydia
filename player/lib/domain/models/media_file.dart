import '../sources/item.dart';

class MediaFile {
  final String id;
  final String? resolution;
  final String? codec;
  final String? audioCodec;
  final String? hdrFormat;
  final int? size;
  final int? bitrate;
  final bool directPlaySupported;
  final String? streamUrl;
  final String? directPlayUrl;

  const MediaFile({
    required this.id,
    this.resolution,
    this.codec,
    this.audioCodec,
    this.hdrFormat,
    this.size,
    this.bitrate,
    required this.directPlaySupported,
    this.streamUrl,
    this.directPlayUrl,
  });

  factory MediaFile.fromJson(Map<String, dynamic> json) {
    return MediaFile(
      id: json['id'].toString(),
      resolution: json['resolution'] as String?,
      codec: json['codec'] as String?,
      audioCodec: json['audioCodec'] as String?,
      hdrFormat: json['hdrFormat'] as String?,
      size: json['size'] as int?,
      bitrate: json['bitrate'] as int?,
      directPlaySupported: json['directPlaySupported'] as bool? ?? false,
      streamUrl: json['streamUrl'] as String?,
      directPlayUrl: json['directPlayUrl'] as String?,
    );
  }

  /// e.g. "1080p • hevc • HDR10", or null when the file says nothing about
  /// its quality; the screen then says it is unknown.
  String? get displayQuality {
    final parts = <String>[
      if (resolution != null) resolution!,
      if (codec != null) codec!,
      if (hdrFormat != null) hdrFormat!,
    ];
    return parts.isEmpty ? null : parts.join(' • ');
  }
}

List<MediaFile> filesFromVersions(List<MediaVersion> versions) => [
      for (final v in versions)
        MediaFile(
          id: v.id,
          resolution: v.height == null ? null : '${v.height}p',
          codec: v.videoCodec,
          audioCodec: v.audioCodec,
          // MediaFile.bitrate is bits per second; versions carry kilobits.
          bitrate: v.bitrateKbps == null ? null : v.bitrateKbps! * 1000,
          size: v.sizeBytes,
          hdrFormat: v.hdrFormat,
          directPlaySupported: v.directPlaySupported ?? true,
        ),
    ];
