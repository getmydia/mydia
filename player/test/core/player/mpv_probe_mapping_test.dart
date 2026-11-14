import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/mpv_probe_mapping.dart';
import 'package:player/domain/models/media_stream.dart';

ProbeResult mapFixture(String name) {
  final json =
      jsonDecode(File('test/fixtures/mpv_probe/$name').readAsStringSync())
          as Map<String, dynamic>;
  return mapMpvProbe(
    fileFormat: json['file-format'] as String?,
    duration: (json['duration'] as num?)?.toDouble(),
    fileSize: (json['file-size'] as num?)?.toInt(),
    trackList: (json['track-list'] as List).cast<Object?>(),
    videoParams: (json['video-params'] as Map?)?.cast<String, Object?>(),
  );
}

void main() {
  test('maps an HEVC 10-bit Dolby Vision MKV', () {
    final r = mapFixture('hevc_dv_mkv.json');
    expect(r.container, 'matroska');
    final v = r.streams.firstWhere((s) => s.type == MediaStreamType.video);
    expect([v.codec, v.width, v.height, v.bitDepth], ['hevc', 3840, 2160, 10]);
    expect([v.colorTransfer, v.colorPrimaries], ['pq', 'bt.2020']);
    expect(v.colorSpace, 'bt.2020-ncl');
    expect(v.pixelFormat, 'yuv420p10');
    expect(v.dolbyVisionProfile, 8);
    expect(v.profile, 'Main 10');
    expect(v.frameRate, closeTo(23.976, 0.001));
    expect(r.resolution, '2160p');
    expect(r.videoCodec, 'hevc');
    final audio =
        r.streams.where((s) => s.type == MediaStreamType.audio).toList();
    expect(audio.where((a) => a.isDefault), hasLength(1));
    expect(audio.where((a) => a.isCommentary), hasLength(1));
    // String-typed numbers are parsed.
    final commentary = audio.firstWhere((a) => a.isCommentary);
    expect([commentary.channels, commentary.sampleRate], [2, 48000]);
    final subs =
        r.streams.where((s) => s.type == MediaStreamType.subtitle).toList();
    expect(subs.where((s) => s.isForced), hasLength(1));
    expect(subs.where((s) => s.isHearingImpaired), hasLength(1));
  });

  test('external tracks are left out', () {
    final r = mapFixture('hevc_dv_mkv.json');
    final subs =
        r.streams.where((s) => s.type == MediaStreamType.subtitle).toList();
    expect(subs, hasLength(3));
    expect(subs.where((s) => s.language == 'fra'), isEmpty);
  });

  test('bitrate sums track bitrates, else falls back to size * 8 / duration',
      () {
    expect(mapFixture('hevc_dv_mkv.json').bitrate, 52000000 + 4200000 + 192000);
    final r = mapFixture('sparse_avi.json');
    expect(r.bitrate, 1000000);
    expect(r.container, 'avi');
  });

  test('audio-only file has no resolution or codec', () {
    final r = mapFixture('audio_only.json');
    expect(r.resolution, isNull);
    expect(r.videoCodec, isNull);
    expect(r.streams.where((s) => s.type == MediaStreamType.video), isEmpty);
    expect(r.streams, hasLength(1));
  });

  test('resolution buckets', () {
    String? res(int h) => ProbeResult(streams: [
          MediaStream(type: MediaStreamType.video, height: h),
        ]).resolution;
    expect([res(2160), res(1080), res(720), res(480), res(304)],
        ['2160p', '1080p', '720p', '480p', '304p']);
  });

  test('toMap/fromMap round-trips', () {
    final r = mapFixture('hevc_dv_mkv.json');
    final back = ProbeResult.fromMap(
        jsonDecode(jsonEncode(r.toMap())) as Map<String, dynamic>);
    expect(back.toMap(), r.toMap());
    expect(back.streams, hasLength(r.streams.length));
    expect(back.container, 'matroska');
    expect(back.durationSeconds, r.durationSeconds);
    final v = back.streams.first;
    expect([v.codec, v.bitDepth, v.colorTransfer, v.dolbyVisionProfile],
        ['hevc', 10, 'pq', 8]);
  });
}
