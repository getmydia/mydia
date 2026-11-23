import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/l10n/l10n.dart';
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
}
