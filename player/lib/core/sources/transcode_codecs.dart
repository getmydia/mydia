/// What a server may transcode to for this device: the device's decoders,
/// narrowed to codecs Plex and Jellyfin both produce.
library;

import '../player/device_profile.dart';

const _videoKnown = {'h264', 'hevc', 'vp9', 'av1'};
const _audioKnown = {'aac', 'ac3', 'eac3', 'mp3', 'opus', 'flac'};

({List<String> video, List<String> audio}) transcodeCodecs(
    DeviceProfile? profile) {
  final video = (profile?.videoCodecs ?? const ['h264'])
      .where(_videoKnown.contains)
      .toList();
  final audio = (profile?.audioCodecs ?? const ['aac', 'ac3'])
      .where(_audioKnown.contains)
      .toList();
  return (
    video: video.isEmpty ? const ['h264'] : video,
    audio: audio.isEmpty ? const ['aac'] : audio,
  );
}
