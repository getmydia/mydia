/// What the stats panel shows, split into the part that is measured every
/// second and the part the screen already knows.
///
/// Two types rather than one because they have different lifetimes and
/// different owners: [StatsSample] comes from
/// `PlaybackStatsCollector`, which can be unit tested without a plan or a
/// `Player`, and [StatsContext] is composed by `PlayerScreen` from the
/// plan, the track list and the p2p status.
library;

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

/// What the screen knows without measuring.
class StatsContext {
  const StatsContext({
    required this.mode,
    required this.qualityLabel,
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
  /// `Auto -> 1080p` or `Original`.
  final String qualityLabel;
  final Duration duration;

  /// One viewer-facing sentence explaining a mode that is not the obvious
  /// one. Null when there is nothing to say, which drops the row.
  final String? why;

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
