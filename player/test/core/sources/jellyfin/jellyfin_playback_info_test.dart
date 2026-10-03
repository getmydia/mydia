import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/device_profile.dart';
import 'package:player/core/sources/jellyfin/jellyfin_playback_info.dart';
import 'package:player/core/sources/transcode_codecs.dart';
import 'package:player/domain/sources/source_error.dart';

import 'jellyfin_media_source_test.dart' show build;

void main() {
  test('transcode codecs keep what servers can produce', () {
    final c = transcodeCodecs(const DeviceProfile(
      containers: ['mp4', 'mkv'],
      videoCodecs: ['h264', 'hevc', 'mpeg2video'],
      audioCodecs: ['aac', 'truehd', 'opus'],
      hdrFormats: [],
    ));
    expect(c.video, ['h264', 'hevc']);
    expect(c.audio, ['aac', 'opus']);
    // Records compare their lists by identity, so check the fields.
    final defaults = transcodeCodecs(null);
    expect(defaults.video, ['h264']);
    expect(defaults.audio, ['aac', 'ac3']);
  });

  test('the device profile offers direct play and an HLS target', () {
    final p = jellyfinDeviceProfile(const DeviceProfile(
      containers: ['mp4', 'mkv'],
      videoCodecs: ['h264', 'hevc'],
      audioCodecs: ['aac', 'eac3'],
      hdrFormats: [],
    ));
    final direct = (p['DirectPlayProfiles'] as List).single as Map;
    expect(direct['Container'], 'mp4,mkv');
    expect(direct['VideoCodec'], 'h264,hevc');
    final hls = (p['TranscodingProfiles'] as List).single as Map;
    expect(hls['Protocol'], 'hls');
    expect(hls['Container'], 'ts');
    expect(hls['AudioCodec'], 'aac,eac3');
    final subs = p['SubtitleProfiles'] as List;
    expect(subs, contains(equals({'Format': 'srt', 'Method': 'External'})));
  });

  test('reads the session id and each source\'s support', () {
    final info = JellyfinPlaybackInfo.fromJson(const {
      'PlaySessionId': 'ps1',
      'MediaSources': [
        {
          'Id': 'm2',
          'SupportsDirectPlay': false,
          'SupportsDirectStream': true,
          'SupportsTranscoding': true,
        },
      ],
    });
    expect(info.playSessionId, 'ps1');
    final s = info.sources['m2']!;
    expect((s.directPlay, s.directStream, s.transcoding), (false, true, true));
  });

  test('an ErrorCode becomes a readable server error', () {
    expect(
      () => JellyfinPlaybackInfo.fromJson(const {'ErrorCode': 'NotAllowed'}),
      throwsA(isA<SourceException>()
          .having((e) => e.viewerMessage, 'message', contains('not allowed'))),
    );
  });

  test('posts the profile for the chosen version', () async {
    final b = build();
    final info = await b.source.playbackInfo('m2',
        mediaSourceId: 'm2', deviceProfile: jellyfinDeviceProfile(null));
    expect(info.playSessionId, 'ps1');
    final (path, body) = b.server.bodies.single;
    expect(path, '/Items/m2/PlaybackInfo');
    expect(body['MediaSourceId'], 'm2');
    expect(body['DeviceProfile'], isA<Map<String, dynamic>>());
    expect(b.server.requests.single.url.queryParameters['userId'], isNotEmpty);
  });
}
