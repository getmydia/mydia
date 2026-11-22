import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/player/subtitle_position.dart';
import 'package:player/core/player/video_scaling.dart';
import 'package:player/presentation/widgets/video_surface/mydia_subtitle_view.dart';
import 'package:player/presentation/widgets/video_surface/surface_subtitle_lift.dart';

class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());
}

class _RecordingController extends MydiaSubtitleViewController {
  EdgeInsets? padding;
  Duration? duration;
  bool reset = false;

  @override
  void setPadding(EdgeInsets padding, {required Duration duration}) {
    this.padding = padding;
    this.duration = duration;
    reset = false;
  }

  @override
  void resetPadding({required Duration duration}) {
    padding = null;
    this.duration = duration;
    reset = true;
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
    // 80 px stays inside the ~92 px bar below a fitted 2.4:1 picture.
    expect(positions, [100]);
  });

  test('a lift taller than the letterbox bar moves bitmap subtitles', () {
    const box = Size(1000, 600);
    final positions = <double>[];
    final lift = SurfaceSubtitleLift(
      player: player,
      subtitles: subtitles,
      box: () => box,
      applyPosition: (_, pos) async => positions.add(pos),
    );

    lift.apply(120, duration: Duration.zero);

    expect(positions.single, closeTo(93.2, 0.05));
  });

  test('fill measures the lift from the box edge: no bar to absorb it', () {
    const box = Size(1000, 600);
    final positions = <double>[];
    final lift = SurfaceSubtitleLift(
      player: player,
      subtitles: subtitles,
      box: () => box,
      scaling: VideoScaling.fill,
      applyPosition: (_, pos) async => positions.add(pos),
    );

    lift.apply(80, duration: Duration.zero);

    expect(positions.single, closeTo(100 - 100 * 80 / 600, 0.001));
  });

  test('back at rest the text returns to the configuration padding', () {
    final lift = SurfaceSubtitleLift(
      player: player,
      subtitles: subtitles,
      box: () => const Size(1000, 600),
      applyPosition: (p, pos) async {},
    );

    lift.apply(80, duration: Duration.zero);
    expect(subtitles.reset, isFalse);
    lift.apply(kSubtitleRestPadding, duration: Duration.zero);
    expect(subtitles.reset, isTrue);
  });

  test('a change of scaling is a different lift, so sub-pos is resent', () {
    SurfaceSubtitleLift lift(VideoScaling scaling) => SurfaceSubtitleLift(
      player: player,
      subtitles: subtitles,
      box: () => const Size(1, 1),
      scaling: scaling,
    );
    expect(lift(VideoScaling.fit), lift(VideoScaling.fit));
    expect(lift(VideoScaling.fit), isNot(lift(VideoScaling.fill)));
  });

  test('equality follows player and subtitles', () {
    final a = SurfaceSubtitleLift(
      player: player,
      subtitles: subtitles,
      box: () => const Size(1, 1),
    );
    final b = SurfaceSubtitleLift(
      player: player,
      subtitles: subtitles,
      box: () => const Size(2, 2),
    );
    final c = SurfaceSubtitleLift(
      player: player,
      subtitles: _RecordingController(),
      box: () => const Size(1, 1),
    );
    final d = SurfaceSubtitleLift(
      player: Player(platformPlayer: _FakePlatformPlayer()),
      subtitles: subtitles,
      box: () => const Size(1, 1),
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(c));
    expect(a, isNot(d));
  });
}
