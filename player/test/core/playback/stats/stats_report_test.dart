import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/stats/playback_stats.dart';
import 'package:player/core/playback/stats/stats_metrics.dart';
import 'package:player/core/playback/stats/stats_report.dart';

const _sample = StatsSample(
  bufferedAhead: Duration(milliseconds: 18400),
  position: Duration(minutes: 24, seconds: 11),
  droppedFrames: 0,
  droppedFramesTotal: 0,
  throughputKbps: 6200,
);

const _context = StatsContext(
  mode: PlaybackMode.transcode,
  qualityLabel: 'Auto -> 1080p',
  duration: Duration(hours: 1, minutes: 52, seconds: 40),
  why: 'Switched to transcoding for this device',
  whyDetail: 'decodeTooSlow: 47 drops in last 10s (limit 12)',
  sourceLabel: '2160p hevc - 14.2 Mb/s - mkv',
  videoLabel: '1920x1080 h264 - 23.976 fps',
  decoderLabel: 'h264 (vaapi)',
  hardwareDecode: true,
  audioLabel: 'eac3 5.1 - 48 kHz - eng',
  linkLabel: 'direct p2p - 1 peer',
);

List<String> labelsOf(List<StatsRow> rows) =>
    rows.map((row) => row.label).toList();

String valueFor(List<StatsRow> rows, String label) =>
    rows.firstWhere((row) => row.label == label).value;

void main() {
  test('the full density shows every row in order', () {
    final rows = statsRows(_sample, _context, StatsDensity.full);

    expect(labelsOf(rows), [
      'Playing',
      'Why',
      'Source',
      'Video',
      'Decoder',
      'Audio',
      'Frames',
      'Buffer',
      'Throughput',
      'Link',
      'Position',
    ]);
  });

  test('values read the way the panel draws them', () {
    final rows = statsRows(_sample, _context, StatsDensity.full);

    expect(valueFor(rows, 'Playing'), 'Auto -> 1080p');
    expect(valueFor(rows, 'Buffer'), '18.4 s ahead');
    expect(valueFor(rows, 'Throughput'), '6.2 Mb/s');
    expect(valueFor(rows, 'Frames'), '0 dropped - 0 total');
    expect(valueFor(rows, 'Decoder'), 'h264 (vaapi) hardware');
    expect(valueFor(rows, 'Position'), '24:11 / 1:52:40');
  });

  // A dash beside a label reads as a fault in the player. A row with
  // nothing to say is not drawn.
  test('a row with no value is left out, not dashed', () {
    const web = StatsContext(
      mode: PlaybackMode.copy,
      qualityLabel: 'Original',
      duration: Duration(minutes: 30),
      linkLabel: 'server - https',
    );
    final rows = statsRows(
      const StatsSample(
        bufferedAhead: Duration(seconds: 4),
        position: Duration(seconds: 90),
      ),
      web,
      StatsDensity.full,
    );

    // The label list is the real assertion: a value the platform does not
    // know produces no row at all, so an implementation that emitted
    // `StatsRow(label: 'Decoder', value: '-')` would fail here.
    expect(labelsOf(rows), ['Playing', 'Buffer', 'Link', 'Position']);
    // And nothing that does render is a bare placeholder. Deliberately not
    // a scan for '-': ' - ' is the field separator in Source, Frames and
    // Audio, so a hyphen anywhere is not the defect. A placeholder
    // standing alone in place of a value is.
    expect(
      rows.every(
        (row) => !const ['', '-', '--', 'n/a', 'unknown']
            .contains(row.value.trim().toLowerCase()),
      ),
      isTrue,
    );
  });

  // The badge the panel draws before the Playing value. Untested badge
  // text would let a casing typo reach the UI silently.
  test('the Playing row carries the mode badge', () {
    expect(
      statsRows(_sample, _context, StatsDensity.full).first.pill,
      'TRANSCODE',
    );

    const direct = StatsContext(
      mode: PlaybackMode.direct,
      qualityLabel: 'Original',
      duration: Duration(minutes: 30),
    );
    expect(
      statsRows(_sample, direct, StatsDensity.full).first.pill,
      'DIRECT',
    );

    const copy = StatsContext(
      mode: PlaybackMode.copy,
      qualityLabel: 'Original',
      duration: Duration(minutes: 30),
    );
    expect(
      statsRows(_sample, copy, StatsDensity.full).first.pill,
      'COPY',
    );

    const localFile = StatsContext(
      mode: PlaybackMode.localFile,
      qualityLabel: 'Original',
      duration: Duration(minutes: 30),
    );
    expect(
      statsRows(_sample, localFile, StatsDensity.full).first.pill,
      isNull,
    );
  });

  // A platform that reports a decoder description but cannot say whether
  // it is hardware falls back to the bare label, with no suffix guessed.
  test('the decoder row has no suffix when hardware is unknown', () {
    const context = StatsContext(
      mode: PlaybackMode.transcode,
      qualityLabel: 'Auto -> 1080p',
      duration: Duration(minutes: 30),
      decoderLabel: 'h264 (vaapi)',
    );
    final rows = statsRows(_sample, context, StatsDensity.full);

    expect(valueFor(rows, 'Decoder'), 'h264 (vaapi)');
  });

  test('a local file reports no throughput and no link', () {
    const local = StatsContext(
      mode: PlaybackMode.localFile,
      qualityLabel: 'Original',
      duration: Duration(minutes: 30),
      videoLabel: '1920x1080 h264 - 23.976 fps',
    );
    final rows = statsRows(
      const StatsSample(
        bufferedAhead: Duration(seconds: 30),
        position: Duration.zero,
        droppedFrames: 0,
        droppedFramesTotal: 3,
      ),
      local,
      StatsDensity.full,
    );

    expect(labelsOf(rows), contains('Frames'));
    expect(labelsOf(rows), isNot(contains('Throughput')));
    expect(labelsOf(rows), isNot(contains('Link')));
    expect(valueFor(rows, 'Playing'), 'Local file');
  });

  // The collector now arms for a downloaded file too (deliberately, so the
  // panel reports on it at all), and `cache-speed` on that code path is an
  // unverified mpv contract. A local file has no server to measure
  // throughput to, so the row and its clipboard line must stay gone even
  // when the sample carries a non-null reading, not only when it happens to
  // be null.
  test(
      'a local file omits Throughput even when the sample carries a '
      'reading', () {
    const local = StatsContext(
      mode: PlaybackMode.localFile,
      qualityLabel: 'Original',
      duration: Duration(minutes: 30),
    );
    const sample = StatsSample(
      bufferedAhead: Duration(seconds: 30),
      position: Duration.zero,
      throughputKbps: 4200,
    );
    final rows = statsRows(sample, local, StatsDensity.full);

    expect(labelsOf(rows), isNot(contains('Throughput')));

    final text = statsClipboardText(sample, local, appVersion: '1.4.2');
    expect(text, isNot(contains('Throughput')));
  });

  test('compact keeps seven rows and drops the long tail', () {
    final rows = statsRows(_sample, _context, StatsDensity.compact);

    expect(labelsOf(rows), [
      'Playing',
      'Why',
      'Video',
      'Frames',
      'Buffer',
      'Throughput',
      'Link',
    ]);
  });

  test('dropped frames read as a warning only when frames drop', () {
    final clean = statsRows(_sample, _context, StatsDensity.full);
    expect(valueFor(clean, 'Frames'), '0 dropped - 0 total');
    expect(
      clean.firstWhere((row) => row.label == 'Frames').tone,
      StatsTone.good,
    );

    final dropping = statsRows(
      const StatsSample(
        bufferedAhead: Duration(seconds: 6),
        position: Duration(minutes: 1),
        droppedFrames: 142,
        droppedFramesTotal: 1402,
      ),
      _context,
      StatsDensity.full,
    );
    expect(valueFor(dropping, 'Frames'), '142 dropped - 1402 total');
    expect(
      dropping.firstWhere((row) => row.label == 'Frames').tone,
      StatsTone.warn,
    );
  });

  test('a relayed link reads as a warning', () {
    const relayed = StatsContext(
      mode: PlaybackMode.transcode,
      qualityLabel: 'Auto -> 720p',
      duration: Duration(minutes: 30),
      linkLabel: 'relayed - 1 peer',
      linkHealthy: false,
    );
    final rows = statsRows(_sample, relayed, StatsDensity.full);

    expect(
      rows.firstWhere((row) => row.label == 'Link').tone,
      StatsTone.warn,
    );
  });

  // The whole point of the copy button: the payload is complete even where
  // the density dropped rows, and it carries the raw adaptation detail the
  // panel deliberately does not show.
  test('the clipboard carries rows the density dropped', () {
    final text = statsClipboardText(
      _sample,
      _context,
      appVersion: '1.4.2',
    );

    expect(text, contains('Mydia Player 1.4.2'));
    expect(text, contains('Source: 2160p hevc - 14.2 Mb/s - mkv'));
    expect(text, contains('Audio: eac3 5.1 - 48 kHz - eng'));
    expect(text, contains('Decoder: h264 (vaapi) hardware'));
    expect(
      text,
      contains('Detail: decodeTooSlow: 47 drops in last 10s (limit 12)'),
    );
    expect(text, contains('Frames: 0 dropped this second, 0 total'));
    expect(text, contains('Buffer: 18.4 s ahead'));
    expect(text, contains('Throughput: 6.2 Mb/s'));
    expect(text, contains('Link: direct p2p - 1 peer'));
    expect(text, contains('Position: 24:11 / 1:52:40'));
  });

  test('the clipboard omits what it does not know', () {
    final text = statsClipboardText(
      const StatsSample(
        bufferedAhead: Duration(seconds: 4),
        position: Duration(seconds: 90),
      ),
      const StatsContext(
        mode: PlaybackMode.direct,
        qualityLabel: 'Original',
        duration: Duration(minutes: 30),
      ),
      appVersion: '1.4.2',
    );

    expect(text, isNot(contains('Decoder:')));
    expect(text, isNot(contains('Detail:')));
    expect(text, contains('Playing: Direct play - Original'));
  });
}
