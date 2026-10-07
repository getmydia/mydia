import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/stream_timeline.dart';
import 'package:player/core/player/video_scaling.dart';
import 'package:player/presentation/widgets/gesture_controls.dart';

/// Never touches native mpv; see gesture_chrome_composition_test.dart.
class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> playOrPause() async {}

  final List<double> volumes = [];

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> seek(Duration duration) async {}
}

Widget _host(Player player, ValueChanged<VideoScaling> onPinch) => MaterialApp(
      home: GestureControls(
        player: player,
        timeline: StreamTimeline.zero,
        onSeekToReal: (_) async {},
        onPinch: onPinch,
        child: const SizedBox.expand(),
      ),
    );

void main() {
  testWidgets('a two-finger spread asks for fill', (tester) async {
    final player = Player(platformPlayer: _FakePlatformPlayer());
    addTearDown(player.dispose);
    final asked = <VideoScaling>[];
    await tester.pumpWidget(_host(player, asked.add));

    final a = await tester.startGesture(const Offset(300, 300), pointer: 1);
    final b = await tester.startGesture(const Offset(400, 300), pointer: 2);
    await b.moveTo(const Offset(500, 300));
    await b.up();
    await a.up();
    await tester.pumpAndSettle();

    expect(asked, [VideoScaling.fill]);
  });

  testWidgets('a single-finger vertical drag never reports a pinch',
      (tester) async {
    final player = Player(platformPlayer: _FakePlatformPlayer());
    addTearDown(player.dispose);
    final asked = <VideoScaling>[];
    await tester.pumpWidget(_host(player, asked.add));

    await tester.dragFrom(const Offset(600, 300), const Offset(0, -150));
    // Let the volume indicator's 500ms hide timer fire.
    await tester.pump(const Duration(seconds: 1));

    expect(asked, isEmpty);
  });

  testWidgets('a diagonal two-finger spread does not change the volume',
      (tester) async {
    final platform = _FakePlatformPlayer();
    final player = Player(platformPlayer: platform);
    addTearDown(player.dispose);
    final asked = <VideoScaling>[];
    await tester.pumpWidget(_host(player, asked.add));

    final a = await tester.startGesture(const Offset(600, 400), pointer: 1);
    final b = await tester.startGesture(const Offset(700, 400), pointer: 2);
    for (var i = 1; i <= 5; i++) {
      await a.moveBy(const Offset(-6, -30));
      await b.moveBy(const Offset(6, -30));
    }
    await b.up();
    await a.up();
    await tester.pump(const Duration(seconds: 1));

    expect(platform.volumes, isEmpty);
    expect(asked, [VideoScaling.fill]);
  });
}
