import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import '../sources/files/backend/file_system_backend.dart';
import 'media_probe.dart';
import 'mpv_probe_mapping.dart';

MediaProbe createPlatformMediaProbe() => MpvMediaProbe();

/// Probes a file with a headless mpv (no video, no audio, paused).
///
/// `getProperty` on node properties such as `track-list` and `video-params`
/// returns mpv's JSON rendering, the same route `decoder-list` is read by in
/// `device_profile_native.dart`.
class MpvMediaProbe implements MediaProbe {
  @override
  Future<ProbeResult?> probe(
    PlayableFile playable, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final stopwatch = Stopwatch()..start();
    Player? player;
    try {
      player = Player();
      final platform = player.platform;
      if (platform is! NativePlayer) return null;

      await platform.setProperty('vo', 'null');
      await platform.setProperty('ao', 'null');
      await platform.setProperty('pause', 'yes');

      // One deadline for everything below, measured from the start of probe.
      Duration remaining() => timeout - stopwatch.elapsed;

      await player
          .open(
            Media(playable.url, httpHeaders: playable.headers),
            play: false,
          )
          .timeout(remaining());

      // media_kit's `Tracks` always carries the `auto` and `no` pseudo-tracks,
      // so its stream cannot say when the file has loaded. Poll mpv's own
      // track-list until it holds a real track.
      List<Object?>? tracks;
      while (remaining() > Duration.zero) {
        final json = await platform.getProperty('track-list');
        final decoded = json.isEmpty ? null : jsonDecode(json);
        if (hasRealTracks(decoded)) {
          tracks = (decoded as List).cast<Object?>();
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (tracks == null) {
        debugPrint('[MediaProbe] no tracks before the deadline');
        return null;
      }

      // Video params arrive a little after the track list.
      final hasVideo = tracks.any((t) => t is Map && t['type'] == 'video');
      if (hasVideo) {
        while (remaining() > Duration.zero &&
            (await platform.getProperty('video-params/w')).isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      // Re-read: codec details can fill in after the first non-empty list.
      final trackJson = await platform.getProperty('track-list');
      final reread = trackJson.isEmpty ? null : jsonDecode(trackJson);
      final decodedTracks = (hasRealTracks(reread) ? reread : tracks) as List;

      final paramsJson = await platform.getProperty('video-params');
      Map<String, Object?>? videoParams;
      if (paramsJson.isNotEmpty) {
        final decoded = jsonDecode(paramsJson);
        if (decoded is Map) videoParams = decoded.cast<String, Object?>();
      }

      final result = mapMpvProbe(
        fileFormat: _nonEmpty(await platform.getProperty('file-format')),
        duration: double.tryParse(await platform.getProperty('duration')),
        fileSize: int.tryParse(await platform.getProperty('file-size')),
        trackList: decodedTracks.cast<Object?>(),
        videoParams: videoParams,
      );
      debugPrint(
        '[MediaProbe] ok in ${stopwatch.elapsedMilliseconds}ms '
        '(${result.streams.length} streams)',
      );
      return result;
    } catch (error) {
      debugPrint(
        '[MediaProbe] failed after ${stopwatch.elapsedMilliseconds}ms: $error',
      );
      return null;
    } finally {
      await player?.dispose();
    }
  }

  static String? _nonEmpty(String value) => value.isEmpty ? null : value;
}
