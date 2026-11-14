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

      final tracksReady = player.stream.tracks
          .firstWhere((t) => t.video.length + t.audio.length > 0);
      // If we bail out early, dispose closes the stream and this future would
      // otherwise complete with an unhandled error.
      unawaited(tracksReady.then<void>((_) {}, onError: (_) {}));
      await player.open(
        Media(playable.url, httpHeaders: playable.headers),
        play: false,
      );

      try {
        await tracksReady.timeout(timeout);
      } on TimeoutException {
        debugPrint('[MediaProbe] timed out waiting for tracks');
        return null;
      }

      // Video params arrive a little after the track list. Wait for the rest
      // of the budget, but only when there is a video track to wait for.
      final hasVideo = player.state.tracks.video.any(
        (t) => t.id != 'auto' && t.id != 'no',
      );
      if (hasVideo) {
        while (stopwatch.elapsed < timeout &&
            (await platform.getProperty('video-params/w')).isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      final trackJson = await platform.getProperty('track-list');
      if (trackJson.isEmpty) return null;
      final decodedTracks = jsonDecode(trackJson);
      if (decodedTracks is! List) return null;

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
