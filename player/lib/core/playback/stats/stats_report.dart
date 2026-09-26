/// The stats panel's rows and its clipboard payload.
///
/// Pure: no widgets, no `Player`, no providers. This is where nearly all
/// of the feature's behaviour is tested, and the reason
/// `StatsSample`/`StatsContext` carry nullable fields rather than
/// pre-formatted strings.
library;

import '../../build_channel.dart';
import '../../format/bitrate.dart';
import 'playback_stats.dart';
import 'stats_metrics.dart';

enum StatsTone { normal, good, warn }

class StatsRow {
  const StatsRow({
    required this.label,
    required this.value,
    this.tone = StatsTone.normal,
    this.pill,
  });

  final String label;
  final String value;
  final StatsTone tone;

  /// Short uppercase badge text drawn before [value], for example
  /// `TRANSCODE`. Only the Playing row sets it. This is the badge's text,
  /// not a boolean flag; the brief's own interface summary said `bool
  /// pill`, which was wrong.
  final String? pill;
}

/// The rows [density] draws, in order, skipping every row whose value is
/// unknown.
///
/// A row is omitted rather than dashed on purpose: a dash beside a label
/// reads as a fault in the player, and the copy payload carries the field
/// either way.
List<StatsRow> statsRows(
  StatsSample sample,
  StatsContext context,
  StatsDensity density,
) {
  final compact = density == StatsDensity.compact;
  final rows = <StatsRow>[
    StatsRow(
      label: 'Playing',
      value: _pill(context.mode) == null
          ? _modeLabel(context.mode)
          : context.qualityLabel,
      pill: _pill(context.mode),
    ),
    if (context.why != null)
      StatsRow(
        label: 'Why',
        value: context.why!,
        tone: StatsTone.warn,
      ),
    if (!compact && context.sourceLabel != null)
      StatsRow(label: 'Source', value: context.sourceLabel!),
    if (context.videoLabel != null)
      StatsRow(label: 'Video', value: context.videoLabel!),
    if (!compact && context.decoderLabel != null)
      StatsRow(label: 'Decoder', value: _decoder(context)),
    if (!compact && context.audioLabel != null)
      StatsRow(label: 'Audio', value: context.audioLabel!),
    if (sample.droppedFrames != null && sample.droppedFramesTotal != null)
      StatsRow(
        label: 'Frames',
        value: '${sample.droppedFrames} dropped '
            '- ${sample.droppedFramesTotal} total',
        tone: sample.droppedFrames! > 0 ? StatsTone.warn : StatsTone.good,
      ),
    StatsRow(label: 'Buffer', value: _seconds(sample.bufferedAhead)),
    // Gated on mode, not just on the sample carrying a reading: a local
    // file has no server to measure throughput to, so a number here would
    // read as a real figure even though `cache-speed` on that code path is
    // an unverified mpv contract -- possibly a disk-read speed, possibly a
    // bogus zero -- that the collector never used to read before the panel
    // started arming it for downloaded files too.
    if (context.mode != PlaybackMode.localFile && sample.throughputKbps != null)
      StatsRow(
        label: 'Throughput',
        value: formatBitrate(sample.throughputKbps!),
      ),
    if (context.linkLabel != null)
      StatsRow(
        label: 'Link',
        value: context.linkLabel!,
        tone: context.linkHealthy ? StatsTone.good : StatsTone.warn,
      ),
    if (!compact)
      StatsRow(
        label: 'Position',
        value: '${_timecode(sample.position)} / '
            '${_timecode(context.duration)}',
      ),
  ];
  return rows;
}

/// Everything the panel knows, whatever the density drew, plus the raw
/// adaptation detail the panel deliberately keeps off screen.
String statsClipboardText(
  StatsSample sample,
  StatsContext context, {
  required String appVersion,
}) {
  final lines = <String>[
    '${BuildChannel.current.appName} $appVersion',
    'Playing: ${_modeLabel(context.mode)} - ${context.qualityLabel}',
    if (context.why != null) 'Why: ${context.why}',
    if (context.whyDetail != null) 'Detail: ${context.whyDetail}',
    if (context.sourceLabel != null) 'Source: ${context.sourceLabel}',
    if (context.videoLabel != null) 'Video: ${context.videoLabel}',
    if (context.decoderLabel != null) 'Decoder: ${_decoder(context)}',
    if (context.audioLabel != null) 'Audio: ${context.audioLabel}',
    if (sample.droppedFrames != null && sample.droppedFramesTotal != null)
      'Frames: ${sample.droppedFrames} dropped this second, '
          '${sample.droppedFramesTotal} total'
    else if (sample.droppedFramesTotal != null)
      'Frames: ${sample.droppedFramesTotal} total',
    'Buffer: ${_seconds(sample.bufferedAhead)}',
    if (context.mode != PlaybackMode.localFile && sample.throughputKbps != null)
      'Throughput: ${formatBitrate(sample.throughputKbps!)}',
    if (context.linkLabel != null) 'Link: ${context.linkLabel}',
    'Position: ${_timecode(sample.position)} / '
        '${_timecode(context.duration)}',
  ];
  return lines.join('\n');
}

String? _pill(PlaybackMode mode) => switch (mode) {
      PlaybackMode.direct => 'DIRECT',
      PlaybackMode.copy => 'COPY',
      PlaybackMode.transcode => 'TRANSCODE',
      PlaybackMode.localFile => null,
    };

String _modeLabel(PlaybackMode mode) => switch (mode) {
      PlaybackMode.direct => 'Direct play',
      PlaybackMode.copy => 'Stream copy',
      PlaybackMode.transcode => 'Transcode',
      PlaybackMode.localFile => 'Local file',
    };

String _decoder(StatsContext context) {
  final hardware = context.hardwareDecode;
  if (hardware == null) return context.decoderLabel!;
  return '${context.decoderLabel!} ${hardware ? 'hardware' : 'software'}';
}

/// One decimal, because a buffer that reads `18 s` for eighteen seconds
/// running looks frozen while `18.4` visibly moves.
String _seconds(Duration duration) {
  final tenths = (duration.inMilliseconds / 100).round();
  return '${tenths ~/ 10}.${tenths % 10} s ahead';
}

/// `24:11` under an hour, `1:52:40` over it. Hours are not zero-padded,
/// matching the chrome's own timecodes.
String _timecode(Duration duration) {
  final total = duration.inSeconds;
  final seconds = (total % 60).toString().padLeft(2, '0');
  final minutes = (total ~/ 60) % 60;
  final hours = total ~/ 3600;
  if (hours == 0) return '$minutes:$seconds';
  return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
}
