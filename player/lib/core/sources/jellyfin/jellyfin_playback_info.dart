/// `POST /Items/{id}/PlaybackInfo`: what this device may do with each of an
/// item's versions, and the play session the reports belong to.
library;

import 'package:flutter/foundation.dart';

import '../../../domain/sources/source_error.dart';
import '../../player/device_profile.dart';
import '../transcode_codecs.dart';

/// A Jellyfin `DeviceProfile`: direct play for what this device decodes,
/// one HLS transcode target, subtitles embedded or as sidecars (never
/// burned in, so mpv keeps track selection).
Map<String, dynamic> jellyfinDeviceProfile(DeviceProfile? profile) {
  final codecs = transcodeCodecs(profile);
  final containers = profile?.containers ?? const ['mp4', 'mkv'];
  return {
    'Name': 'Mydia Player',
    'MaxStreamingBitrate': 120000000,
    'DirectPlayProfiles': [
      {
        'Type': 'Video',
        'Container': containers.join(','),
        'VideoCodec': (profile?.videoCodecs ?? codecs.video).join(','),
        'AudioCodec': (profile?.audioCodecs ?? codecs.audio).join(','),
      },
    ],
    'TranscodingProfiles': [
      {
        'Type': 'Video',
        'Container': 'ts',
        'Protocol': 'hls',
        'Context': 'Streaming',
        'VideoCodec': codecs.video.join(','),
        'AudioCodec': codecs.audio.join(','),
        'BreakOnNonKeyFrames': true,
      },
    ],
    'SubtitleProfiles': [
      for (final f in const [
        'srt',
        'subrip',
        'ass',
        'ssa',
        'vtt',
        'webvtt',
        'pgssub',
        'dvdsub',
      ])
        {'Format': f, 'Method': 'Embed'},
      for (final f in const ['srt', 'ass', 'ssa', 'vtt'])
        {'Format': f, 'Method': 'External'},
    ],
    'ContainerProfiles': const <Map<String, dynamic>>[],
    'CodecProfiles': const <Map<String, dynamic>>[],
  };
}

String jellyfinPlaybackError(String code) => switch (code) {
      'NotAllowed' => 'Your Jellyfin account is not allowed to play this.',
      'NoCompatibleStream' =>
        'Jellyfin found no way to play this file on this device.',
      'RateLimitExceeded' =>
        'Jellyfin limits how much this account can stream right now.',
      _ => 'Jellyfin refused to play this ($code).',
    };

@immutable
class JellyfinSourceSupport {
  const JellyfinSourceSupport({
    required this.id,
    required this.directPlay,
    required this.directStream,
    required this.transcoding,
  });

  final String id;
  final bool directPlay;
  final bool directStream;
  final bool transcoding;
}

@immutable
class JellyfinPlaybackInfo {
  const JellyfinPlaybackInfo({
    required this.playSessionId,
    required this.sources,
  });

  factory JellyfinPlaybackInfo.fromJson(Map<String, dynamic> json) {
    if (json['ErrorCode'] case final String code) {
      throw SourceException.server(jellyfinPlaybackError(code));
    }
    return JellyfinPlaybackInfo(
      playSessionId: json['PlaySessionId'] as String? ?? '',
      sources: {
        for (final s in (json['MediaSources'] as List? ?? const []))
          if (s is Map && s['Id'] is String)
            s['Id'] as String: JellyfinSourceSupport(
              id: s['Id'] as String,
              directPlay: s['SupportsDirectPlay'] == true,
              directStream: s['SupportsDirectStream'] == true,
              transcoding: s['SupportsTranscoding'] == true,
            ),
      },
    );
  }

  final String playSessionId;
  final Map<String, JellyfinSourceSupport> sources;
}
