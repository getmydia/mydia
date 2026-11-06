// Television-tier focus memory on the movie detail page: the hero's button
// bar and the similar rail each remember their place, so UP and DOWN between
// them round-trip. Mounted in the real shell regions (`TvShell`), whose
// traversal policy carries `FocusMemory.requestFocus`.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/detail/source_detail_controllers.dart';
import 'package:player/presentation/screens/movie/movie_detail_screen.dart';
import 'package:player/presentation/widgets/hero_play_control.dart';
import 'package:player/presentation/widgets/primary_play_button.dart';
import 'package:player/presentation/widgets/smart_play_button.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../../test_utils/mock_network_images.dart';
import '../../../test_utils/tv_shell_harness.dart';
import '../sources/fake_media_source.dart';
import 'detail_harness.dart';

Key _action(String id) => ValueKey('detail-action-$id');
Key _similar(int n) => ValueKey('source-poster-m$n');

void main() {
  /// Asserts focus is on the Play pill itself, not the version picker beside
  /// it.
  void expectOnPlay() => expect(
        find.descendant(
          of: find.byElementPredicate(
              (e) => e == FocusManager.instance.primaryFocus?.context),
          matching: find.byKey(PrimaryPlayButton.pillKey),
        ),
        findsOneWidget,
        reason: 'focus is on ${describeFocus()}',
      );

  group('movie detail focus memory (TV)', () {
    Future<void> pumpMovie(
      WidgetTester tester, {
      List<MediaVersion> versions = const [
        MediaVersion(id: 'v1', height: 1080)
      ],
    }) async {
      final movie = fakeMovie(1).ref;
      final source = ScriptedDetailSource(
        detailOf: (ref) => ItemDetail(
          summary: fakeMovie(1),
          overview: 'An invented film.',
          // A full cast rail sits between the hero bar and the similar rail.
          // Its cards have no action, so they are not focus stops, and a
          // press between the two must pass over it.
          cast: [for (var i = 0; i < 30; i++) Person(name: 'Actor $i')],
          versions: versions,
        ),
      );
      await mockNetworkImages(() => TvShell().pump(
            tester,
            MovieDetailScreen.target(target: SourceTarget(movie)),
            overrides: [
              mediaSourceProvider(source.id).overrideWithValue(source),
              sourceArtworkProvider.overrideWith((ref, key) async => null),
              sourceSimilarProvider(movie).overrideWith((_) =>
                  Stream.value([for (var n = 2; n < 20; n++) fakeMovie(n)])),
            ],
          ));
      // Watched, Download, Info: the fake source has no favorites and the
      // movie no trailer.
      expect(find.byKey(_action('watched')), findsOneWidget);
      expect(find.byKey(_action('download')), findsOneWidget);
      expect(find.byKey(_action('info')), findsOneWidget);
    }

    testWidgets(
        'from Play, DOWN steps through the hero bar and the similar rail, '
        'and UP climbs back to Play', (tester) async {
      await pumpMovie(tester);
      await focusIn(tester, HeroPlayControl.sectionKey);

      // Play sits at the hero's right, the button bar under it at the left:
      // left to the geometric search, DOWN from Play overlaps the similar
      // rail instead and skips the bar.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(_action('watched'));
      // The cast rail between has no focus stops.
      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(_similar(2));

      await press(tester, LogicalKeyboardKey.arrowUp);
      expectFocusIn(_action('watched'));
      // Left to the geometric search, UP from the bar reaches the back
      // button straight above it.
      await press(tester, LogicalKeyboardKey.arrowUp);
      expectFocusIn(HeroPlayControl.sectionKey);
    });

    testWidgets('the hero bar is entered first on its first button',
        (tester) async {
      await pumpMovie(tester);
      // m6 sits right of the hero bar, so the nearest button straight up is
      // its last one.
      await focusIn(tester, _similar(6));

      await press(tester, LogicalKeyboardKey.arrowUp);

      expectFocusIn(_action('watched'));
    });

    testWidgets('the hero bar is re-entered on the button that left it',
        (tester) async {
      await pumpMovie(tester);
      await focusIn(tester, _action('info'));

      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(_similar(2));
      // A sideways move drops Flutter's own up/down history, so the return
      // below is the hero bar's memory and not a replay.
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(_similar(5));
      await press(tester, LogicalKeyboardKey.arrowUp);

      expectFocusIn(_action('info'));
    });

    testWidgets('the similar rail is re-entered on its card after scrolling',
        (tester) async {
      await pumpMovie(tester);
      await focusIn(tester, _similar(2));
      for (var i = 0; i < 10; i++) {
        await press(tester, LogicalKeyboardKey.arrowRight);
      }
      expectFocusIn(_similar(12));

      await press(tester, LogicalKeyboardKey.arrowUp);
      expectFocusIn(_action('watched'));
      await press(tester, LogicalKeyboardKey.arrowRight);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(_action('info'));
      await press(tester, LogicalKeyboardKey.arrowDown);

      expectFocusIn(_similar(12));
    });

    testWidgets('the Play section is re-entered on the version picker',
        (tester) async {
      // With two versions Play waits on the network probe to pick one, and
      // stays disabled, so not a focus stop, until it answers. An unmocked
      // channel never answers under the test clock.
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'),
        (call) async => ['ethernet'],
      );
      addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
                const MethodChannel('dev.fluttercommunity.plus/connectivity'),
                null,
              ));
      await pumpMovie(tester, versions: const [
        MediaVersion(id: 'v1', height: 1080),
        MediaVersion(id: 'v2', height: 2160),
      ]);
      expect(find.byKey(SmartPlayButton.versionPickerKey), findsOneWidget);
      // The page opens on Play, not on the picker that was focusable first.
      expectOnPlay();
      // First entry lands on Play. Play's focus node attaches once the
      // version is picked, after the picker's, so a section that took its
      // first node in focus-tree order would land on the picker.
      await focusIn(tester, _action('watched'));
      await press(tester, LogicalKeyboardKey.arrowUp);
      expectOnPlay();

      await press(tester, LogicalKeyboardKey.arrowRight);
      expectFocusIn(SmartPlayButton.versionPickerKey);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expectFocusIn(_action('watched'));
      await press(tester, LogicalKeyboardKey.arrowUp);

      expectFocusIn(SmartPlayButton.versionPickerKey);
    });
  }, skip: tvSkipReason);
}
