import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show SubtitleViewConfiguration;
import 'package:player/presentation/widgets/video_surface/mydia_subtitle_view.dart';

class _FakePlatformPlayer extends PlatformPlayer {
  _FakePlatformPlayer() : super(configuration: const PlayerConfiguration());

  void emitSubtitle(List<String> lines) {
    state = state.copyWith(subtitle: lines);
    if (!subtitleController.isClosed) subtitleController.add(lines);
  }
}

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: SizedBox(width: 400, height: 300, child: child)),
    );

EdgeInsets _padding(WidgetTester tester) => tester
    .widget<Padding>(find.descendant(
      of: find.byType(AnimatedContainer),
      matching: find.byType(Padding),
    ))
    .padding as EdgeInsets;

void main() {
  late _FakePlatformPlayer platform;
  late Player player;

  setUp(() {
    platform = _FakePlatformPlayer();
    player = Player(platformPlayer: platform);
  });

  testWidgets('shows streamed lines joined by newlines', (tester) async {
    await tester.pumpWidget(_host(MydiaSubtitleView(
      player: player,
      configuration: const SubtitleViewConfiguration(),
    )));
    platform.emitSubtitle(['first line', 'second line']);
    await tester.pump();
    expect(find.text('first line\nsecond line'), findsOneWidget);
  });

  testWidgets('shows nothing for blank lines', (tester) async {
    await tester.pumpWidget(_host(MydiaSubtitleView(
      player: player,
      configuration: const SubtitleViewConfiguration(),
    )));
    platform.emitSubtitle(['', '']);
    await tester.pump();
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.data, '');
  });

  testWidgets('starts from the current player state', (tester) async {
    platform.state = platform.state.copyWith(subtitle: ['already here']);
    await tester.pumpWidget(_host(MydiaSubtitleView(
      player: player,
      configuration: const SubtitleViewConfiguration(),
    )));
    expect(find.text('already here'), findsOneWidget);
  });

  testWidgets('setPadding animates the padding over the duration',
      (tester) async {
    final controller = MydiaSubtitleViewController();
    await tester.pumpWidget(_host(MydiaSubtitleView(
      player: player,
      configuration: const SubtitleViewConfiguration(),
      controller: controller,
    )));
    expect(_padding(tester).bottom, 24);

    controller.setPadding(
      const EdgeInsets.fromLTRB(16, 0, 16, 80),
      duration: const Duration(milliseconds: 200),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final mid = _padding(tester).bottom;
    expect(mid, greaterThan(24));
    expect(mid, lessThan(80));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_padding(tester).bottom, 80);
  });

  testWidgets('a new configuration padding applies while nothing lifts',
      (tester) async {
    Widget view(double bottom) => _host(MydiaSubtitleView(
          player: player,
          configuration: SubtitleViewConfiguration(
              padding: EdgeInsets.fromLTRB(16, 0, 16, bottom)),
        ));
    await tester.pumpWidget(view(24));
    expect(_padding(tester).bottom, 24);

    await tester.pumpWidget(view(40));
    await tester.pumpAndSettle();
    expect(_padding(tester).bottom, 40);
  });

  testWidgets('resetPadding follows the configuration again after a lift',
      (tester) async {
    final controller = MydiaSubtitleViewController();
    Widget view(double bottom) => _host(MydiaSubtitleView(
          player: player,
          configuration: SubtitleViewConfiguration(
              padding: EdgeInsets.fromLTRB(16, 0, 16, bottom)),
          controller: controller,
        ));
    await tester.pumpWidget(view(24));
    controller.setPadding(const EdgeInsets.fromLTRB(16, 0, 16, 80),
        duration: Duration.zero);
    await tester.pumpAndSettle();
    controller.resetPadding(duration: Duration.zero);
    await tester.pumpAndSettle();

    await tester.pumpWidget(view(40));
    await tester.pumpAndSettle();
    expect(_padding(tester).bottom, 40);
  });
}
