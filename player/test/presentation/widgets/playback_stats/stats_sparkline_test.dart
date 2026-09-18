import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/stats/playback_stats.dart';
import 'package:player/presentation/widgets/playback_stats/stats_sparkline.dart';

List<StatsPoint> points(int count) => List.generate(
      count,
      (i) => StatsPoint(bufferedMs: 9000 + i * 100, throughputKbps: 5000 + i),
    );

Future<void> pump(WidgetTester tester, List<StatsPoint> history) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: StatsSparkline(history: history, width: 320, height: 54),
        ),
      ),
    ),
  );
}

void main() {
  // The first seconds of a source have almost no history. A two-point line
  // says nothing and reads as a rendering fault, so nothing is drawn.
  testWidgets('draws nothing below the minimum point count', (tester) async {
    await pump(tester, points(StatsSparkline.minimumPoints - 1));

    expect(find.byKey(StatsSparkline.painterKey), findsNothing);
  });

  testWidgets('draws once there is enough history', (tester) async {
    await pump(tester, points(StatsSparkline.minimumPoints));

    expect(find.byKey(StatsSparkline.painterKey), findsOneWidget);
    final box = tester.getSize(find.byKey(StatsSparkline.painterKey));
    expect(box.width, 320);
    expect(box.height, 54);
  });

  // A flat window would divide by a zero range. It has to render, not
  // throw, because a healthy stream on a fast link is exactly that.
  testWidgets('a flat window renders', (tester) async {
    await pump(
      tester,
      List.generate(
        30,
        (_) => const StatsPoint(bufferedMs: 30000, throughputKbps: 6000),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(StatsSparkline.painterKey), findsOneWidget);
  });

  // Throughput is null on web and for a local file, where the buffer line
  // still has something to say.
  testWidgets('a history with no throughput still renders', (tester) async {
    await pump(
      tester,
      List.generate(30, (i) => StatsPoint(bufferedMs: 5000 + i * 200)),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(StatsSparkline.painterKey), findsOneWidget);
  });
}
