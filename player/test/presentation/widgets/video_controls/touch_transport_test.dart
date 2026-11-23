import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/semantics.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/widgets/controls/press_scale.dart';
import 'package:player/presentation/widgets/video_controls/control_button.dart';
import 'package:player/presentation/widgets/video_controls/touch_transport.dart';
import 'package:player/presentation/widgets/video_controls/transport_cluster.dart';

/// A [PlatformPlayer] that never touches native bindings, counting the
/// play and pause calls.
class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  int plays = 0;
  int pauses = 0;

  @override
  Future<void> play() async => plays++;

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> playOrPause() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> seek(Duration duration) async {}
}

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  late _FakePlatformPlayer platform;
  late Player player;

  setUp(() {
    platform = _FakePlatformPlayer();
    player = Player(platformPlayer: platform);
  });

  tearDown(() => player.dispose());

  TouchTransport build({
    bool showEpisodeNav = false,
    VoidCallback? onPrevious,
    VoidCallback? onNext,
    VoidCallback? onBack10,
    VoidCallback? onForward10,
  }) => TouchTransport(
    player: player,
    onBack10: onBack10 ?? () {},
    onForward10: onForward10 ?? () {},
    onPreviousEpisode: onPrevious,
    onNextEpisode: onNext,
    showEpisodeNav: showEpisodeNav,
  );

  testWidgets('shows -10, play, +10 and no episode buttons by default', (
    tester,
  ) async {
    await tester.pumpWidget(_host(build(onPrevious: () {}, onNext: () {})));

    expect(find.byKey(TransportSurface.back10Key), findsOneWidget);
    expect(find.byKey(TransportSurface.playPauseKey), findsOneWidget);
    expect(find.byKey(TransportSurface.forward10Key), findsOneWidget);
    expect(find.byKey(TransportSurface.previousEpisodeKey), findsNothing);
    expect(find.byKey(TransportSurface.nextEpisodeKey), findsNothing);

    expect(
      tester.getSize(find.byKey(TransportSurface.playPauseKey)),
      const Size(TouchTransport.playSize, TouchTransport.playSize),
    );
    expect(
      tester.widget<ControlButton>(find.byKey(TransportSurface.back10Key)).size,
      TouchTransport.seekSize,
    );
  });

  testWidgets(
    'shows previous and next when showEpisodeNav and callbacks are set',
    (tester) async {
      var previous = 0;
      var next = 0;
      await tester.pumpWidget(
        _host(
          build(
            showEpisodeNav: true,
            onPrevious: () => previous++,
            onNext: () => next++,
          ),
        ),
      );

      expect(find.byKey(TransportSurface.previousEpisodeKey), findsOneWidget);
      expect(find.byKey(TransportSurface.nextEpisodeKey), findsOneWidget);

      await tester.tap(find.byKey(TransportSurface.previousEpisodeKey));
      await tester.tap(find.byKey(TransportSurface.nextEpisodeKey));
      expect(previous, 1);
      expect(next, 1);
    },
  );

  testWidgets('omits episode buttons when their callbacks are null', (
    tester,
  ) async {
    await tester.pumpWidget(_host(build(showEpisodeNav: true)));

    expect(find.byKey(TransportSurface.previousEpisodeKey), findsNothing);
    expect(find.byKey(TransportSurface.nextEpisodeKey), findsNothing);
  });

  testWidgets('seek buttons call their callbacks', (tester) async {
    var back = 0;
    var forward = 0;
    await tester.pumpWidget(
      _host(build(onBack10: () => back++, onForward10: () => forward++)),
    );

    await tester.tap(find.byKey(TransportSurface.back10Key));
    await tester.tap(find.byKey(TransportSurface.forward10Key));
    expect(back, 1);
    expect(forward, 1);
  });

  testWidgets('play toggles the player', (tester) async {
    await tester.pumpWidget(_host(build()));

    await tester.tap(find.byKey(TransportSurface.playPauseKey));
    await tester.pump();
    expect(platform.plays, 1);
    expect(platform.pauses, 0);
  });

  testWidgets('contains no BackdropFilter', (tester) async {
    await tester.pumpWidget(
      _host(build(showEpisodeNav: true, onPrevious: () {}, onNext: () {})),
    );

    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('the play disc announces "Play" once, with a tap action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(build()));

    final labelled = find.bySemanticsLabel('Play');
    expect(labelled, findsOneWidget);
    final data = tester.getSemantics(labelled).getSemanticsData();
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(data.label, 'Play');
    // The tooltip would merge into the same node and be read after the
    // label, so it must contribute nothing.
    expect(data.tooltip, isEmpty);
    expect(
      find.semantics.byPredicate((node) {
        final d = node.getSemanticsData();
        return d.label == 'Play' || d.tooltip == 'Play';
      }),
      findsOne,
    );
    handle.dispose();
  });

  testWidgets('buffering swaps the play glyph for a dark spinner', (
    tester,
  ) async {
    platform.state = platform.state.copyWith(buffering: true);
    await tester.pumpWidget(_host(build()));

    expect(find.byKey(TouchTransport.bufferingKey), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    final spinner = tester.widget<CircularProgressIndicator>(
      find.descendant(
        of: find.byKey(TouchTransport.bufferingKey),
        matching: find.byType(CircularProgressIndicator),
      ),
    );
    expect(spinner.color, TouchTransport.playGlyph);
  });

  testWidgets('each disc has exactly one press animation', (tester) async {
    await tester.pumpWidget(
      _host(build(showEpisodeNav: true, onPrevious: () {}, onNext: () {})),
    );

    // The seek and episode discs scale inside ControlButton, so no
    // PressScale wraps them; the play disc is not a ControlButton and keeps
    // its PressScale.
    for (final key in const [
      TransportSurface.previousEpisodeKey,
      TransportSurface.back10Key,
      TransportSurface.forward10Key,
      TransportSurface.nextEpisodeKey,
    ]) {
      expect(
        find.ancestor(of: find.byKey(key), matching: find.byType(PressScale)),
        findsNothing,
        reason: '$key',
      );
    }
    expect(
      find.ancestor(
        of: find.byKey(TransportSurface.playPauseKey),
        matching: find.byType(PressScale),
      ),
      findsOneWidget,
    );
  });
}
