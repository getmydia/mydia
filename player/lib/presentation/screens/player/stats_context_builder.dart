/// Composes the stats panel's `StatsContext` from what the player screen
/// already knows.
///
/// A free function with explicit parameters rather than a method on
/// `_PlayerScreenState`, for two reasons: `player_screen.dart` is over
/// 5,000 lines, and the interesting behaviour here is the Why row, which
/// deserves a test that does not need a `Player`.
library;

import 'package:media_kit/media_kit.dart';

import '../../../core/format/bitrate.dart';
import '../../../core/playback/adaptation_policy.dart' as policy;
import '../../../core/playback/playback_memory.dart';
import '../../../core/playback/playback_plan.dart';
import '../../../core/playback/stats/playback_stats.dart';
import '../../../domain/models/quality_rung.dart';

/// A fallback the policy performed during this session.
class StatsFallback {
  const StatsFallback({required this.reason, required this.detail});

  final FailureReason reason;

  /// The policy's own detail string, composed for `debugPrint`. It goes to
  /// the clipboard, never to the panel.
  final String detail;
}

/// The viewer-facing sentence for [reason]. Re-exported so the test does
/// not have to reach into `adaptation_policy.dart` for it.
String fallbackMessageFor(FailureReason reason) =>
    policy.fallbackMessage(reason);

StatsContext buildStatsContext({
  required PlaybackPlan? plan,
  required bool isDownloadedSource,
  required QualityRung selectedQuality,
  required QualityRung? effectiveQuality,
  required Duration duration,
  required StatsFallback? lastFallback,
  required Set<FailureKey> knownFailures,
  required int? sourceHeight,
  required String? sourceCodec,
  required int? sourceBitrateKbps,
  required String? sourceContainer,
  required VideoTrack? videoTrack,
  required AudioTrack? audioTrack,
  required String? linkLabel,
  required bool linkHealthy,
}) {
  final mode = _mode(plan, isDownloadedSource);
  final why = _why(
    mode: mode,
    lastFallback: lastFallback,
    selectedQuality: selectedQuality,
    knownFailures: knownFailures,
    sourceHeight: sourceHeight,
    sourceCodec: sourceCodec,
  );

  return StatsContext(
    mode: mode,
    qualityLabel: _qualityLabel(selectedQuality, effectiveQuality),
    duration: duration,
    why: why,
    whyDetail: lastFallback?.detail,
    sourceLabel: mode == PlaybackMode.localFile
        ? null
        : _sourceLabel(
            sourceHeight,
            sourceCodec,
            sourceBitrateKbps,
            sourceContainer,
          ),
    videoLabel: _videoLabel(videoTrack),
    decoderLabel: videoTrack?.decoder,
    hardwareDecode: _hardwareDecode(videoTrack?.decoder),
    audioLabel: _audioLabel(audioTrack),
    linkLabel: mode == PlaybackMode.localFile ? null : linkLabel,
    linkHealthy: linkHealthy,
  );
}

PlaybackMode _mode(PlaybackPlan? plan, bool isDownloadedSource) {
  if (isDownloadedSource || plan == null) return PlaybackMode.localFile;
  return switch (plan) {
    DirectPlayPlan() => PlaybackMode.direct,
    HlsPlan(strategy: HlsStrategy.copy) => PlaybackMode.copy,
    HlsPlan() => PlaybackMode.transcode,
  };
}

/// The Why row, or null when the mode needs no explaining.
///
/// A fallback that actually happened wins: it is the more specific answer
/// and it carries a raw detail worth pasting. Otherwise the reason is
/// derived from the plan, in the order a viewer would ask about it.
String? _why({
  required PlaybackMode mode,
  required StatsFallback? lastFallback,
  required QualityRung selectedQuality,
  required Set<FailureKey> knownFailures,
  required int? sourceHeight,
  required String? sourceCodec,
}) {
  if (lastFallback != null) {
    return policy.fallbackMessage(lastFallback.reason);
  }
  switch (mode) {
    case PlaybackMode.direct:
    case PlaybackMode.localFile:
      return null;
    case PlaybackMode.copy:
      return 'Container is not playable directly';
    case PlaybackMode.transcode:
      if (!selectedQuality.isAuto && !selectedQuality.isOriginal) {
        return 'Quality capped to ${selectedQuality.label}';
      }
      final remembered = _rememberedFailure(
        knownFailures,
        sourceHeight,
        sourceCodec,
      );
      if (remembered != null) {
        return 'Remembered decode failure on $remembered';
      }
      return 'Server is re-encoding for this device';
  }
}

String? _rememberedFailure(
  Set<FailureKey> knownFailures,
  int? sourceHeight,
  String? sourceCodec,
) {
  if (sourceCodec == null) return null;
  for (final key in knownFailures) {
    if (key.videoCodec == sourceCodec) return key.videoCodec;
  }
  return null;
}

String _qualityLabel(QualityRung selected, QualityRung? effective) {
  if (selected.isAuto) {
    return effective == null ? 'Auto' : 'Auto -> ${effective.label}';
  }
  return selected.label;
}

String? _sourceLabel(
  int? height,
  String? codec,
  int? bitrateKbps,
  String? container,
) {
  final parts = <String>[
    if (height != null) '${height}p',
    if (codec != null) codec,
  ];
  if (parts.isEmpty) return null;
  final tail = <String>[
    if (bitrateKbps != null) formatBitrate(bitrateKbps),
    if (container != null) container,
  ];
  return [parts.join(' '), ...tail].join(' - ');
}

String? _videoLabel(VideoTrack? track) {
  if (track == null) return null;
  final size =
      track.w != null && track.h != null ? '${track.w}x${track.h}' : null;
  final head = [
    if (size != null) size,
    if (track.codec != null) track.codec!,
  ].join(' ');
  if (head.isEmpty) return null;
  final fps = track.fps;
  if (fps == null) return head;
  return '$head - ${_fps(fps)} fps';
}

String? _audioLabel(AudioTrack? track) {
  if (track == null) return null;
  final parts = <String>[
    if (track.codec != null) track.codec!,
    if (track.channels != null) track.channels!,
  ].join(' ');
  final tail = <String>[
    if (track.samplerate != null) '${track.samplerate! ~/ 1000} kHz',
    if (track.language != null && track.language != 'und') track.language!,
  ];
  if (parts.isEmpty && tail.isEmpty) return null;
  return [if (parts.isNotEmpty) parts, ...tail].join(' - ');
}

/// mpv's `decoder-desc` names the hardware path in parentheses, for
/// example `h264 (vaapi)` or `h264 (mediacodec)`. A bare codec name is
/// software.
bool? _hardwareDecode(String? decoder) {
  if (decoder == null) return null;
  return decoder.contains('(');
}

/// Three decimals where they matter (23.976), none where they do not (25).
String _fps(double fps) {
  final rounded = fps.roundToDouble();
  if ((fps - rounded).abs() < 0.001) return rounded.toInt().toString();
  return fps.toStringAsFixed(3);
}
