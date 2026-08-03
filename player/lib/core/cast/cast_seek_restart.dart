import 'cast_backend.dart';

/// How far ahead of the current position a cast seek may target before the
/// session is restarted instead.
///
/// Matches local playback's `kSeekRestartTolerance` deliberately: a restart is
/// far more disruptive than the small snap-back it avoids, and a 10-second
/// skip or a double-tap-forward must never tear a session down.
const Duration kCastSeekRestartTolerance = Duration(seconds: 30);

/// Whether a cast seek must restart the server-side session rather than seek
/// the receiver in place.
///
/// Only ever true for [CastMediaKind.hls]. A progressive route hands the
/// receiver a byte-range stream of the whole file: [startOffset] is always
/// zero, the whole runtime is addressable, and a receiver seek anywhere in it
/// is valid. Restarting there would tear down and reload a session for a
/// target it could already reach.
///
/// For HLS there are two independent reasons, mirroring the local predicate's
/// two clauses:
///
/// 1. [target] is before [startOffset], so it is not present in this stream
///    at all. No amount of seeking can reach it.
/// 2. [target] is far enough ahead of [currentPosition] that FFmpeg has
///    probably not written it yet. Unlike local playback there is no way to
///    know for sure: a Chromecast reports `duration: -1` for a live-style
///    playlist forever, so the transcoded extent is unobservable and distance
///    from the current position is the only available proxy.
bool shouldRestartCastForSeek({
  required CastMediaKind mediaKind,
  required Duration target,
  required Duration currentPosition,
  required Duration startOffset,
  Duration tolerance = kCastSeekRestartTolerance,
}) {
  if (mediaKind != CastMediaKind.hls) return false;
  if (target < startOffset) return true;
  return target > currentPosition + tolerance;
}
