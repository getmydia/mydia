// The shared watch-indicator contract.
//
// Every surface that composes WatchIndicator runs this, the same way every
// surface composing PosterFrame runs runPosterDepthContract. Composing the
// widget is necessary but not sufficient: a surface can still draw its own
// dot, keep a stale progress bar beside the new one, or drop the indicator
// out of its overlay list entirely, and none of that is visible from inside
// WatchIndicator.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/watch_status.dart';
import 'package:player/presentation/widgets/progress_overlay.dart';
import 'package:player/presentation/widgets/watch_indicator.dart';

import 'mock_network_images.dart';
import 'poster_contract.dart';

/// Asserts that [build] renders the four watch states the same way every
/// other surface does.
///
/// [build] receives a status and must return the surface under test wired to
/// it. Pass the same [size] the surface's other tests use.
void runWatchIndicatorContract({
  required String description,
  required Widget Function(WatchStatus? status) build,
  Size? size,
}) {
  Future<void> pump(WidgetTester tester, WatchStatus? status) async {
    await mockNetworkImages(() async {
      await tester.pumpWidget(posterHost(build(status), size: size));
      await tester.pumpAndSettle();
    });
  }

  group('$description watch indicator contract', () {
    testWidgets('draws a dot when the title was never played', (tester) async {
      await pump(tester, const WatchStatus(watched: false));

      expect(find.byKey(WatchIndicator.dotKey), findsOneWidget);
    });

    testWidgets('draws the unwatched count for a container', (tester) async {
      await pump(
        tester,
        const WatchStatus(watched: false, unwatchedEpisodeCount: 7),
      );

      expect(find.text('7'), findsOneWidget);
      expect(find.byKey(WatchIndicator.dotKey), findsNothing);
    });

    testWidgets('draws a bar and no dot while part-played', (tester) async {
      await pump(tester, const WatchStatus(watched: false, percentage: 40));

      expect(find.byType(ProgressOverlay), findsOneWidget);
      expect(find.byKey(WatchIndicator.dotKey), findsNothing);
    });

    testWidgets('draws nothing at all once watched', (tester) async {
      await pump(tester, const WatchStatus(watched: true, percentage: 100));

      expect(find.byKey(WatchIndicator.dotKey), findsNothing);
      expect(find.byType(ProgressOverlay), findsNothing);
    });

    testWidgets('draws nothing when the server sent no status', (tester) async {
      await pump(tester, null);

      expect(find.byKey(WatchIndicator.dotKey), findsNothing);
      expect(find.byType(ProgressOverlay), findsNothing);
    });
  });
}
