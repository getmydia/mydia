/// What a cast receiver is assumed to decode. Conservative on purpose: every
/// Chromecast generation and the Default Media Receiver play H.264 with AAC
/// or MP3, and a source transcodes anything else.
library;

import '../player/device_profile.dart';

const receiverDeviceProfile = DeviceProfile(
  containers: ['mp4', 'ts'],
  videoCodecs: ['h264'],
  audioCodecs: ['aac', 'mp3'],
  hdrFormats: [],
);

const _h264 = {'h264', 'avc', 'avc1'};

bool receiverCanCopyVideo(String? videoCodec) =>
    videoCodec != null && _h264.contains(videoCodec.toLowerCase());

const _imageSubtitleCodecs = {
  'pgs',
  'pgssub',
  'hdmv_pgs_subtitle',
  'dvdsub',
  'dvd_subtitle',
  'dvbsub',
  'dvb_subtitle',
  'vobsub',
};

/// Bitmap subtitles cannot become WebVTT.
bool isImageSubtitleCodec(String? codec) =>
    codec != null && _imageSubtitleCodecs.contains(codec.toLowerCase());
