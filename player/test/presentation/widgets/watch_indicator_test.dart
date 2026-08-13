import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/watch_status.dart';
import 'package:player/presentation/widgets/progress_overlay.dart';
import 'package:player/presentation/widgets/watch_indicator.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Stack(children: [child])),
    );

void main() {
  group('WatchIndicator', () {
    testWidgets('draws a count for a container with episodes left',
        (tester) async {
      await tester.pumpWidget(
        _host(const WatchIndicator(
          status: WatchStatus(watched: false, unwatchedEpisodeCount: 12),
        )),
      );

      expect(find.text('12'), findsOneWidget);
      expect(find.byKey(WatchIndicator.dotKey), findsNothing);
    });

    testWidgets('draws a dot for a never-played title', (tester) async {
      await tester.pumpWidget(
        _host(const WatchIndicator(status: WatchStatus(watched: false))),
      );

      expect(find.byKey(WatchIndicator.dotKey), findsOneWidget);
    });

    testWidgets('draws nothing at all once watched', (tester) async {
      await tester.pumpWidget(
        _host(const WatchIndicator(
          status: WatchStatus(watched: true, percentage: 100),
        )),
      );

      expect(find.byKey(WatchIndicator.dotKey), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('draws no dot while a title is part-played', (tester) async {
      await tester.pumpWidget(
        _host(const WatchIndicator(
          status: WatchStatus(watched: false, percentage: 40),
        )),
      );

      expect(find.byKey(WatchIndicator.dotKey), findsNothing);
    });

    testWidgets('draws nothing for a watched show with a zero count',
        (tester) async {
      await tester.pumpWidget(
        _host(const WatchIndicator(
          status: WatchStatus(watched: true, unwatchedEpisodeCount: 0),
        )),
      );

      expect(find.byKey(WatchIndicator.dotKey), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('draws nothing when the server sent no status at all',
        (tester) async {
      await tester.pumpWidget(_host(const WatchIndicator(status: null)));

      expect(find.byKey(WatchIndicator.dotKey), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('renders a large count without truncating it', (tester) async {
      await tester.pumpWidget(
        _host(const WatchIndicator(
          status: WatchStatus(watched: false, unwatchedEpisodeCount: 137),
        )),
      );

      expect(find.text('137'), findsOneWidget);
    });
  });

  group('WatchProgressOverlay', () {
    testWidgets('draws the bar for a part-played title', (tester) async {
      await tester.pumpWidget(
        _host(const WatchProgressOverlay(
          status: WatchStatus(watched: false, percentage: 40),
        )),
      );

      expect(find.byType(ProgressOverlay), findsOneWidget);
    });

    testWidgets('draws no bar once watched', (tester) async {
      await tester.pumpWidget(
        _host(const WatchProgressOverlay(
          status: WatchStatus(watched: true, percentage: 100),
        )),
      );

      expect(find.byType(ProgressOverlay), findsNothing);
    });

    testWidgets('draws no bar for a never-played title', (tester) async {
      await tester.pumpWidget(
        _host(const WatchProgressOverlay(status: WatchStatus(watched: false))),
      );

      expect(find.byType(ProgressOverlay), findsNothing);
    });

    testWidgets('draws no bar when the server sent no status', (tester) async {
      // The degradation path for a player talking to a server that predates
      // `watchStatus`: the field comes back absent, the status is null, and
      // every surface must render as it did before rather than throw.
      await tester.pumpWidget(_host(const WatchProgressOverlay(status: null)));

      expect(find.byType(ProgressOverlay), findsNothing);
    });

    testWidgets('draws no bar for a show', (tester) async {
      await tester.pumpWidget(
        _host(const WatchProgressOverlay(
          status: WatchStatus(watched: false, unwatchedEpisodeCount: 3),
        )),
      );

      expect(find.byType(ProgressOverlay), findsNothing);
    });
  });
}
