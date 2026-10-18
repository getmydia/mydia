import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:player/presentation/widgets/glass/glass_interaction.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/primary_play_button.dart';

Widget _host(VoidCallback? onPressed, {required bool liquid}) => MaterialApp(
      theme: AppTheme.build(Palettes.projectionBooth, liquid: liquid),
      home: Scaffold(
        body: Center(child: PrimaryPlayButton(onPressed: onPressed)),
      ),
    );

void main() {
  testWidgets('Liquid Glass: a neutral glass capsule that plays',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(() => taps++, liquid: true));
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(GlassInteraction), findsOneWidget);
    expect(find.byKey(PrimaryPlayButton.pillKey), findsOneWidget);
    final glass =
        tester.widget<GlassSurface>(find.byKey(PrimaryPlayButton.pillKey));
    expect(glass.liquidAdaptiveMax, DepthTokens.liquidControlAdaptiveMax);
    expect(glass.liquidTintOpacity, DepthTokens.liquidControlTintOpacity);
    expect(tester.widget<Icon>(find.byIcon(Icons.play_arrow_rounded)).color,
        Colors.white);
    expect(tester.widget<Text>(find.text('Play')).style?.color, Colors.white);
    expect(tester.widget<FocusHighlight>(find.byType(FocusHighlight)).ringColor,
        Colors.white);
    await tester.tap(find.byKey(PrimaryPlayButton.pillKey));
    expect(taps, 1);
  });

  testWidgets('disabled on Liquid Glass keeps the solid disabled pill',
      (tester) async {
    await tester.pumpWidget(_host(null, liquid: true));
    expect(find.byType(GlassSurface), findsNothing);
  });

  testWidgets('Frosted it is the solid white pill', (tester) async {
    await tester.pumpWidget(_host(() {}, liquid: false));
    expect(find.byType(GlassSurface), findsNothing);
    final pill = tester.widget<Material>(find.byKey(PrimaryPlayButton.pillKey));
    expect(pill.color, Colors.white);
  });
}
