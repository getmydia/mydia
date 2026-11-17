import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/subtitle_position.dart';
import 'package:player/presentation/widgets/video_surface/mydia_subtitle_view.dart';
import 'package:player/presentation/widgets/video_surface/surface_subtitle_lift.dart';

class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());
}

class _RecordingController extends MydiaSubtitleViewController {
  EdgeInsets? padding;
  Duration? duration;

  @override
  void setPadding(EdgeInsets padding, {required Duration duration}) {
    this.padding = padding;
    this.duration = duration;
  }
}

void main() {
  late Player player;
  late _RecordingController subtitles;

  setUp(() {
    final platform = _FakePlatformPlayer();
    platform.state = platform.state.copyWith(width: 1920, height: 800);
    player = Player(platformPlayer: platform);
    subtitles = _RecordingController();
  });

  test('apply sets the text padding and the bitmap position', () {
    const box = Size(1000, 600);
    final positions = <double>[];
    final lift = SurfaceSubtitleLift(
      player: player,
      subtitles: subtitles,
      box: () => box,
      applyPosition: (_, pos) async => positions.add(pos),
    );

    lift.apply(80, duration: const Duration(milliseconds: 250));

    expect(subtitles.padding, const EdgeInsets.fromLTRB(16, 0, 16, 80));
    expect(subtitles.duration, const Duration(milliseconds: 250));
    expect(positions, [
      subPosForLift(lift: 80, box: box, videoWidth: 1920, videoHeight: 800),
    ]);
  });

  test('equality follows player and subtitles', () {
    final a = SurfaceSubtitleLift(
        player: player, subtitles: subtitles, box: () => const Size(1, 1));
    final b = SurfaceSubtitleLift(
        player: player, subtitles: subtitles, box: () => const Size(2, 2));
    final c = SurfaceSubtitleLift(
        player: player,
        subtitles: _RecordingController(),
        box: () => const Size(1, 1));
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));
  });
}
