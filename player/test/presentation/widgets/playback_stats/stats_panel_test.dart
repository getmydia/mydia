import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/stats/playback_stats.dart';
import 'package:player/core/playback/stats/stats_metrics.dart';
import 'package:player/presentation/widgets/playback_stats/stats_panel.dart';
import 'package:player/presentation/widgets/playback_stats/stats_sparkline.dart';

const _sample = StatsSample(
  bufferedAhead: Duration(milliseconds: 18400),
  position: Duration(minutes: 24, seconds: 11),
  droppedFrames: 0,
  droppedFramesTotal: 0,
  throughputKbps: 6200,
  history: [],
);

StatsSample sampleWithHistory() => StatsSample(
      bufferedAhead: const Duration(milliseconds: 18400),
      position: const Duration(minutes: 24, seconds: 11),
      droppedFrames: 0,
      droppedFramesTotal: 0,
      throughputKbps: 6200,
      history: List.generate(
        30,
        (i) => StatsPoint(bufferedMs: 18000 + i * 40, throughputKbps: 6200),
      ),
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

Future<StatsMetrics> pumpPanel(
  WidgetTester tester, {
  required Size viewport,
  bool tv = false,
  StatsSample sample = _sample,
  StatsContext context = _context,
  VoidCallback? onCopy,
  VoidCallback? onClose,
}) async {
  final metrics = StatsMetrics.resolve(
    viewport: viewport,
    directionalPrimary: tv,
  )!;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox(
          width: viewport.width,
          height: viewport.height,
          child: Stack(
            children: [
              Positioned(
                top: metrics.top,
                left: metrics.gutter,
                child: StatsPanel(
                  sample: sample,
                  context: context,
                  metrics: metrics,
                  onCopy: onCopy,
                  onClose: onClose,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return metrics;
}

void main() {
  testWidgets('the full panel draws every row and the sparkline',
      (tester) async {
    await pumpPanel(
      tester,
      viewport: const Size(1280, 720),
      sample: sampleWithHistory(),
    );

    for (final label in const [
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
    ]) {
      expect(
        find.byKey(StatsPanel.rowKey(label)),
        findsOneWidget,
        reason: 'expected a $label row',
      );
    }
    expect(find.byKey(StatsSparkline.painterKey), findsOneWidget);
  });

  testWidgets('compact drops the long tail and the sparkline', (tester) async {
    await pumpPanel(
      tester,
      viewport: const Size(844, 390),
      sample: sampleWithHistory(),
    );

    expect(find.byKey(StatsPanel.rowKey('Playing')), findsOneWidget);
    expect(find.byKey(StatsPanel.rowKey('Source')), findsNothing);
    expect(find.byKey(StatsPanel.rowKey('Audio')), findsNothing);
    expect(find.byKey(StatsPanel.rowKey('Position')), findsNothing);
    expect(find.byKey(StatsSparkline.painterKey), findsNothing);
  });

  // A focusable button in the panel would join D-pad traversal and fight
  // the OSD's own focus scope. The remote tier dismisses the panel from
  // the quality sheet instead.
  testWidgets('the tv panel has no buttons', (tester) async {
    await pumpPanel(
      tester,
      viewport: const Size(1920, 1080),
      tv: true,
      sample: sampleWithHistory(),
      onCopy: () {},
      onClose: () {},
    );

    expect(find.byKey(StatsPanel.copyKey), findsNothing);
    expect(find.byKey(StatsPanel.closeKey), findsNothing);
    expect(find.byType(IconButton), findsNothing);
  });

  testWidgets('a row with no value is absent from the tree', (tester) async {
    await pumpPanel(
      tester,
      viewport: const Size(1280, 720),
      context: const StatsContext(
        mode: PlaybackMode.direct,
        qualityLabel: 'Original',
        duration: Duration(minutes: 30),
        linkLabel: 'server - https',
      ),
      sample: const StatsSample(
        bufferedAhead: Duration(seconds: 4),
        position: Duration(seconds: 90),
      ),
    );

    expect(find.byKey(StatsPanel.rowKey('Decoder')), findsNothing);
    expect(find.byKey(StatsPanel.rowKey('Frames')), findsNothing);
    expect(find.byKey(StatsPanel.rowKey('Throughput')), findsNothing);
    expect(find.byKey(StatsPanel.rowKey('Link')), findsOneWidget);
  });

  testWidgets('the buttons report taps', (tester) async {
    var copied = 0;
    var closed = 0;
    await pumpPanel(
      tester,
      viewport: const Size(1280, 720),
      sample: sampleWithHistory(),
      onCopy: () => copied++,
      onClose: () => closed++,
    );

    await tester.tap(find.byKey(StatsPanel.copyKey));
    await tester.tap(find.byKey(StatsPanel.closeKey));
    await tester.pump();

    expect(copied, 1);
    expect(closed, 1);
  });

  // The row set and the Why row's text length both vary at runtime, so the
  // panel's content height cannot be pinned to a declared constant (see
  // `StatsMetrics.fullMinHeight`'s dartdoc). What must hold instead is that
  // the panel never draws past the room `StatsMetrics.resolve` measured out
  // for it: it either shrinks to its content or scrolls to stay inside
  // `metrics.maxHeight`, and never throws a layout exception doing either.
  testWidgets('each variant never exceeds its available height',
      (tester) async {
    for (final probe in const [
      (Size(1280, 720), false),
      (Size(844, 390), false),
      (Size(1920, 1080), true),
    ]) {
      final metrics = await pumpPanel(
        tester,
        viewport: probe.$1,
        tv: probe.$2,
        sample: sampleWithHistory(),
        onCopy: () {},
        onClose: () {},
      );

      expect(tester.takeException(), isNull);
      final height = tester.getSize(find.byKey(StatsPanel.panelKey)).height;
      expect(
        height,
        lessThanOrEqualTo(metrics.maxHeight),
        reason: 'panel at ${probe.$1} rendered ${height}px against '
            '${metrics.maxHeight}px available',
      );
    }
  });

  // A future change that clips the overflowing rows instead of scrolling
  // them would still pass the height assertion above (a clipped panel also
  // never exceeds `metrics.maxHeight`), so it needs its own guard: the
  // compact panel's content is taller than the 844x390 phone's available
  // room, so it must expose a real `Scrollable` to reach the rows that do
  // not fit.
  testWidgets('the compact panel scrolls its rows', (tester) async {
    await pumpPanel(
      tester,
      viewport: const Size(844, 390),
      sample: sampleWithHistory(),
      onCopy: () {},
      onClose: () {},
    );

    expect(
      find.descendant(
        of: find.byKey(StatsPanel.panelKey),
        matching: find.byType(Scrollable),
      ),
      findsWidgets,
    );
  });
}
