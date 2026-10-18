import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/glass_icon_button.dart';
import 'package:player/presentation/widgets/glass/glass_interaction.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

ThemeData _theme({required bool liquid}) =>
    AppTheme.build(Palettes.projectionBooth, liquid: liquid);

Widget _host(VoidCallback onPressed, {required bool liquid}) => MaterialApp(
      theme: _theme(liquid: liquid),
      home: Scaffold(
        body: Center(
          child: GlassIconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            tooltip: 'Back',
            onPressed: onPressed,
          ),
        ),
      ),
    );

void main() {
  testWidgets('on Liquid Glass it is a glass circle that still taps',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(() => taps++, liquid: true));
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(GlassInteraction), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    await tester.tap(find.byType(GlassIconButton));
    expect(taps, 1);
  });

  testWidgets('on Frosted it is the plain IconButton', (tester) async {
    await tester.pumpWidget(_host(() {}, liquid: false));
    expect(find.byType(GlassSurface), findsNothing);
    expect(find.byType(IconButton), findsOneWidget);
  });

  testWidgets('it is 44 points unconstrained and fits a 40 point row to 32',
      (tester) async {
    Widget button() => GlassIconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () {},
        );
    await tester.pumpWidget(MaterialApp(
      theme: _theme(liquid: true),
      home: Scaffold(body: Center(child: button())),
    ));
    expect(tester.getSize(find.byType(GlassSurface)), const Size(44, 44));

    await tester.pumpWidget(MaterialApp(
      theme: _theme(liquid: true),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(height: 40, child: Center(child: button())),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(GlassSurface)), const Size(32, 32));
  });
}
