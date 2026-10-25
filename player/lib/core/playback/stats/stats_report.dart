/// The stats panel's rows and its clipboard payload.
///
/// Pure: no widgets, no `Player`, no providers. This is where nearly all
/// of the feature's behaviour is tested, and the reason
/// `StatsSample`/`StatsContext` carry nullable fields rather than
/// pre-formatted strings.
///
/// Rows carry a [StatsRowId] and a typed [StatsValue], not words: the panel
/// names the row and words the value in the viewer's language
/// (`AppFormatters.statsRowLabel`, `AppFormatters.statsValue`). The clipboard
/// text stays English on purpose, because it is pasted into bug reports.
library;

import '../../build_channel.dart';
import '../../format/bitrate.dart';
import 'playback_stats.dart';
import 'stats_metrics.dart';

enum StatsTone { normal, good, warn }

/// Which row this is. Stable, so a test or a widget key can name a row
/// without depending on the label's language.
enum StatsRowId {
  playing,
  why,
  source,
  video,
  decoder,
  audio,
  frames,
  buffer,
  throughput,
  link,
  position,
}

/// What a row's value says. Text that came from the player, the server or the
/// screen is [StatsText] and is shown as it is; the rest is data that the
/// panel words in the viewer's language.
sealed class StatsValue {
  const StatsValue();
}

class StatsText extends StatsValue {
  const StatsText(this.text);
  final String text;
}

class StatsModeValue extends StatsValue {
  const StatsModeValue(this.mode);
  final PlaybackMode mode;
}

class StatsDecoderValue extends StatsValue {
  const StatsDecoderValue(this.label, this.hardware);
  final String label;

  /// Null when the platform cannot say.
  final bool? hardware;
}

class StatsFramesValue extends StatsValue {
  const StatsFramesValue({required this.dropped, required this.total});
  final int dropped;
  final int total;
}

class StatsBufferValue extends StatsValue {
  const StatsBufferValue(this.ahead);
  final Duration ahead;
}

class StatsPositionValue extends StatsValue {
  const StatsPositionValue({required this.position, required this.duration});
  final Duration position;
  final Duration duration;
}

class StatsRow {
  const StatsRow({
    required this.id,
    required this.value,
    this.tone = StatsTone.normal,
    this.pill,
  });

  final StatsRowId id;
  final StatsValue value;
  final StatsTone tone;

  /// The mode whose short uppercase badge (`TRANSCODE`) is drawn before
  /// [value]. Only the Playing row sets it, and a local file has none.
  final PlaybackMode? pill;
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
  final pill = _pill(context.mode);
  final rows = <StatsRow>[
    StatsRow(
      id: StatsRowId.playing,
      value: pill == null
          ? StatsModeValue(context.mode)
          : StatsText(context.qualityLabel),
      pill: pill,
    ),
    if (context.why != null)
      StatsRow(
        id: StatsRowId.why,
        value: StatsText(context.why!),
        tone: StatsTone.warn,
      ),
    if (!compact && context.sourceLabel != null)
      StatsRow(id: StatsRowId.source, value: StatsText(context.sourceLabel!)),
    if (context.videoLabel != null)
      StatsRow(id: StatsRowId.video, value: StatsText(context.videoLabel!)),
    if (!compact && context.decoderLabel != null)
      StatsRow(
        id: StatsRowId.decoder,
        value: StatsDecoderValue(
          context.decoderLabel!,
          context.hardwareDecode,
        ),
      ),
    if (!compact && context.audioLabel != null)
      StatsRow(id: StatsRowId.audio, value: StatsText(context.audioLabel!)),
    if (sample.droppedFrames != null && sample.droppedFramesTotal != null)
      StatsRow(
        id: StatsRowId.frames,
        value: StatsFramesValue(
          dropped: sample.droppedFrames!,
          total: sample.droppedFramesTotal!,
        ),
        tone: sample.droppedFrames! > 0 ? StatsTone.warn : StatsTone.good,
      ),
    StatsRow(
      id: StatsRowId.buffer,
      value: StatsBufferValue(sample.bufferedAhead),
    ),
    // Gated on mode, not just on the sample carrying a reading: a local
    // file has no server to measure throughput to, so a number here would
    // read as a real figure even though `cache-speed` on that code path is
    // an unverified mpv contract -- possibly a disk-read speed, possibly a
    // bogus zero -- that the collector never used to read before the panel
    // started arming it for downloaded files too.
    if (context.mode != PlaybackMode.localFile && sample.throughputKbps != null)
      StatsRow(
        id: StatsRowId.throughput,
        value: StatsText(formatBitrate(sample.throughputKbps!)),
      ),
    if (context.linkLabel != null)
      StatsRow(
        id: StatsRowId.link,
        value: StatsText(context.linkLabel!),
        tone: context.linkHealthy ? StatsTone.good : StatsTone.warn,
      ),
    if (!compact)
      StatsRow(
        id: StatsRowId.position,
        value: StatsPositionValue(
          position: sample.position,
          duration: context.duration,
        ),
      ),
  ];
  return rows;
}

/// Everything the panel knows, whatever the density drew, plus the raw
/// adaptation detail the panel deliberately keeps off screen.
///
/// English whatever the viewer's language: it is pasted into bug reports,
/// where a fixed vocabulary is what makes two reports comparable.
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
    'Position: ${statsTimecode(sample.position)} / '
        '${statsTimecode(context.duration)}',
  ];
  return lines.join('\n');
}

/// The mode that gets a badge. A local file is not a delivery decision, so it
/// has none.
PlaybackMode? _pill(PlaybackMode mode) =>
    mode == PlaybackMode.localFile ? null : mode;

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
String statsTimecode(Duration duration) {
  final total = duration.inSeconds;
  final seconds = (total % 60).toString().padLeft(2, '0');
  final minutes = (total ~/ 60) % 60;
  final hours = total ~/ 3600;
  if (hours == 0) return '$minutes:$seconds';
  return '$hours:${minutes.toString().padLeft(2, '0')}:$seconds';
}
