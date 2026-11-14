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
  /// How long to wait for the first decoded frame's colour fields.
  static const _videoParamsCap = Duration(seconds: 3);

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
      await platform.setProperty('mute', 'yes');
      await platform.setProperty('volume', '0');

      // One deadline for everything below, measured from the start of probe.
      Duration remaining() => timeout - stopwatch.elapsed;

      // A file mpv cannot open ends the load with an error; stop polling then
      // instead of waiting out the deadline.
      Object? loadError;
      final errorSub = player.stream.error.listen((e) => loadError = e);
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
      while (remaining() > Duration.zero && loadError == null) {
        final json = await platform.getProperty('track-list');
        final decoded = json.isEmpty ? null : jsonDecode(json);
        if (hasRealTracks(decoded)) {
          tracks = (decoded as List).cast<Object?>();
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      if (tracks == null) {
        debugPrint(
          '[MediaProbe] no tracks (${loadError ?? 'deadline'}) after '
          '${stopwatch.elapsedMilliseconds}ms',
        );
        return null;
      }

      // A paused player never decodes a frame, so video-params stays empty.
      // Let it run silently (vo/ao null, muted) until the first frame, within
      // a short cap and the overall deadline.
      final hasVideo = tracks.any((t) => t is Map && t['type'] == 'video');
      if (hasVideo) {
        // media_kit starts with vid=no (no video decoding) until a
        // VideoController attaches, so ask for the video track explicitly.
        await platform.setProperty('vid', 'auto');
        await platform.setProperty('pause', 'no');
        final cap = stopwatch.elapsed + _videoParamsCap;
        while (remaining() > Duration.zero &&
            stopwatch.elapsed < cap &&
            (await platform.getProperty('video-params/w')).isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      await errorSub.cancel();

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
