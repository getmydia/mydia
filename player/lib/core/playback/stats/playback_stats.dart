/// What the stats panel shows, split into the part that is measured every
/// second and the part the screen already knows.
///
/// Two types rather than one because they have different lifetimes and
/// different owners: [StatsSample] comes from
/// `PlaybackStatsCollector`, which can be unit tested without a plan or a
/// `Player`, and [StatsContext] is composed by `PlayerScreen` from the
/// plan, the track list and the p2p status.
library;

import '../../../domain/models/quality_rung.dart';
import '../playback_memory.dart' show FailureReason;

/// How the current source is reaching the decoder.
enum PlaybackMode {
  /// The file's own bytes, no server-side work.
  direct,

  /// An HLS session stream-copying the original streams.
  copy,

  /// An HLS session re-encoding.
  transcode,

  /// A downloaded file playing off local storage. No server, so no
  /// throughput and no link.
  localFile,
}

/// One point in the 60-second history behind the sparkline.
class StatsPoint {
  const StatsPoint({required this.bufferedMs, this.throughputKbps});

  /// Null where the platform reports no throughput, which the sparkline
  /// draws as a gap rather than as zero.
  final int? throughputKbps;
  final int bufferedMs;
}

/// The measured second.
class StatsSample {
  const StatsSample({
    required this.bufferedAhead,
    required this.position,
    this.droppedFrames,
    this.droppedFramesTotal,
    this.throughputKbps,
    this.history = const [],
  });

  /// Frames dropped since the previous sample. Null on the first sample of
  /// a source, and null wherever the engine reports no counters.
  final int? droppedFrames;

  /// Frames dropped since this source opened.
  final int? droppedFramesTotal;

  /// Measured delivery throughput. Null off native, null for a local file,
  /// and null once the last good reading has gone stale.
  final int? throughputKbps;

  /// How far past [position] the player has buffered. Never negative.
  final Duration bufferedAhead;
  final Duration position;

  /// Oldest first, at most 60 entries.
  final List<StatsPoint> history;
}

/// The sentences of the Why row that carry no data.
enum StatsWhyKind {
  containerNotDirect,
  copyRejectedByMime,
  serverReencoding,
  browserReencodes,
  switchedEarlier,
  recentStall,
}

/// Why the panel says the current delivery is not the obvious one, as data.
/// `AppFormatters.statsWhyText` words it in the viewer's language and
/// `statsClipboardText` words it in English for bug reports.
sealed class StatsWhy {
  const StatsWhy();
}

/// A sentence with nothing to fill in.
final class StatsWhyPlain extends StatsWhy {
  const StatsWhyPlain(this.kind);
  final StatsWhyKind kind;

  @override
  bool operator ==(Object other) =>
      other is StatsWhyPlain && other.kind == kind;

  @override
  int get hashCode => kind.hashCode;
}

/// The viewer capped the quality at [rung].
final class StatsWhyCapped extends StatsWhy {
  const StatsWhyCapped(this.rung);
  final QualityRung rung;

  @override
  bool operator ==(Object other) =>
      other is StatsWhyCapped && other.rung == rung;

  @override
  int get hashCode => rung.hashCode;
}

/// A decode failure remembered for [codec] is why the file is transcoded.
final class StatsWhyRemembered extends StatsWhy {
  const StatsWhyRemembered(this.codec);
  final String codec;

  @override
  bool operator ==(Object other) =>
      other is StatsWhyRemembered && other.codec == codec;

  @override
  int get hashCode => codec.hashCode;
}

/// The connection stalled [minutes] ago (at least one) and capped the plan.
final class StatsWhyStalled extends StatsWhy {
  const StatsWhyStalled(this.minutes);
  final int minutes;

  @override
  bool operator ==(Object other) =>
      other is StatsWhyStalled && other.minutes == minutes;

  @override
  int get hashCode => minutes.hashCode;
}

/// The adaptation policy switched to transcoding for [reason].
final class StatsWhyFallback extends StatsWhy {
  const StatsWhyFallback(this.reason);
  final FailureReason reason;

  @override
  bool operator ==(Object other) =>
      other is StatsWhyFallback && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;
}

/// The viewer's quality choice and what it resolved to.
class StatsQuality {
  const StatsQuality({required this.selected, this.effective});

  final QualityRung selected;

  /// The rung the server reported applying. Only read when [selected] is Auto.
  final QualityRung? effective;
}

/// What the screen knows without measuring.
class StatsContext {
  const StatsContext({
    required this.mode,
    required this.qualityLabel,
    this.quality,
    required this.duration,
    this.why,
    this.whyDetail,
    this.sourceLabel,
    this.videoLabel,
    this.decoderLabel,
    this.hardwareDecode,
    this.audioLabel,
    this.linkLabel,
    this.linkHealthy = true,
  });

  final PlaybackMode mode;

  /// The viewer's choice and what it resolved to, for example
  /// `Auto -> 1080p` or `Original`. English, for the clipboard: the panel
  /// words [quality] when it is set and falls back to this text otherwise.
  final String qualityLabel;

  /// The same choice as data, for the panel to word in the viewer's language.
  final StatsQuality? quality;
  final Duration duration;

  /// Why a mode that is not the obvious one was chosen. Null when there is
  /// nothing to say, which drops the row.
  final StatsWhy? why;

  /// The raw adaptation detail behind [why], for the clipboard only.
  final String? whyDetail;

  /// The file as the server describes it, for example
  /// `2160p hevc - 14.2 Mb/s - mkv`.
  final String? sourceLabel;

  /// What the decoder is actually handling, for example
  /// `1920x1080 h264 - 23.976 fps`.
  final String? videoLabel;

  /// mpv's `decoder-desc`. Null on web.
  final String? decoderLabel;

  /// Whether [decoderLabel] names a hardware decoder. Null when unknown.
  final bool? hardwareDecode;

  /// The selected audio track, for example `eac3 5.1 - 48 kHz - eng`.
  final String? audioLabel;

  /// How the bytes are arriving, for example `direct p2p - 1 peer`. Null
  /// for a local file.
  final String? linkLabel;

  /// False on a relayed link, which colours the row's dot.
  final bool linkHealthy;
}
