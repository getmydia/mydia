import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/presentation/widgets/video_controls/chrome_panel.dart';
import 'package:player/presentation/widgets/video_controls/chrome_top_bar.dart';
import 'package:player/presentation/widgets/video_controls/up_next_countdown.dart';
import 'package:player/presentation/widgets/video_controls/up_next_policy.dart';
import 'package:player/presentation/widgets/video_controls/up_next_prompt.dart';

const _minAlpha = 0.80;

void main() {
  testWidgets('every text style in the expanded card is legible on glass',
      (tester) async {
    final countdown = UpNextCountdown(onElapsed: () {});
    addTearDown(countdown.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Stack(children: [
      UpNextPrompt(
          target: const UpNextTarget(
              episodeId: 'ep-8',
              fileId: 'file-8',
              seasonNumber: 1,
              episodeNumber: 8,
              title: 'Narkina 5'),
          countdown: countdown,
          metrics: PanelMetrics.forWidth(1280),
          onPlayNow: () {},
          onDismiss: () {},
          onEngagedChanged: (_) {},
          tier: PlayerGlassTier.faux),
    ]))));
    await tester.tap(find.byKey(UpNextPrompt.pillKey));
    await tester.pumpAndSettle();
    final texts = tester.widgetList<Text>(find.descendant(
        of: find.byKey(UpNextPrompt.cardKey), matching: find.byType(Text)));
    expect(texts, isNotEmpty);
    for (final text in texts) {
      final style = text.style;
      expect(style, isNotNull, reason: '"${text.data}" has no explicit style');
      final color = style!.color;
      expect(color, isNotNull, reason: '"${text.data}" has no explicit color');
      if (color!.a >= .99 && color.r < .1) continue;
      expect(color.a, greaterThanOrEqualTo(_minAlpha),
          reason: '"${text.data}" is under the measured glass floor');
      expect(style.shadows, GlassPill.textShadow,
          reason:
              '"${text.data}" needs the shadow that carries 0.80 past 4.5:1');
    }
  });
}
