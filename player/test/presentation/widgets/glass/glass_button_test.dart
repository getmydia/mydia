import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/glass_button.dart';
import 'package:player/presentation/widgets/glass/glass_interaction.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

const _key = Key('glass-button-under-test');

ThemeData _theme({required bool liquid}) =>
    AppTheme.build(Palettes.projectionBooth, liquid: liquid);

Widget _host(VoidCallback? onPressed, {bool liquid = true}) => MaterialApp(
      theme: _theme(liquid: liquid),
      home: Scaffold(
        body: Center(
          child: GlassButton(
            label: 'All episodes',
            onPressed: onPressed,
            buttonKey: _key,
          ),
        ),
      ),
    );

void main() {
  testWidgets('on Liquid Glass it is a glass capsule that taps by key',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(() => taps++));
    expect(find.byType(GlassSurface), findsOneWidget);
    expect(find.byType(GlassInteraction), findsOneWidget);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.text('All episodes'), findsOneWidget);
    await tester.tap(find.byKey(_key));
    expect(taps, 1);
    expect(tester.getSize(find.byType(GlassSurface)).height, 48);
  });

  testWidgets('on Frosted it is the OutlinedButton, keyed', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(() => taps++, liquid: false));
    expect(find.byType(GlassSurface), findsNothing);
    expect(find.byType(OutlinedButton), findsOneWidget);
    await tester.tap(find.byKey(_key));
    expect(taps, 1);
  });

  testWidgets('a null onPressed disables the glass press', (tester) async {
    await tester.pumpWidget(_host(null));
    final interaction =
        tester.widget<GlassInteraction>(find.byType(GlassInteraction));
    expect(interaction.enabled, isFalse);
  });

  testWidgets('the glass path is a labelled button, enabled by onPressed',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(() {}));
    expect(
      tester.getSemantics(find.bySemanticsLabel('All episodes')),
      matchesSemantics(
        label: 'All episodes',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        hasTapAction: true,
        isFocusable: false,
      ),
    );
    await tester.pumpWidget(_host(null));
    expect(
      tester.getSemantics(find.bySemanticsLabel('All episodes')),
      matchesSemantics(
        label: 'All episodes',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('a null onPressed dims the label to textDisabled',
      (tester) async {
    await tester.pumpWidget(_host(() {}));
    final enabled = tester.widget<Text>(find.text('All episodes')).style!.color;
    expect(enabled, Colors.white);
    await tester.pumpWidget(_host(null));
    final ctx = tester.element(find.byType(GlassButton));
    expect(tester.widget<Text>(find.text('All episodes')).style!.color,
        ctx.palette.textDisabled);
  });

  testWidgets('grouped passes through to the glass surface', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: _theme(liquid: true),
      home: BackdropGroup(
        child: GlassButton(label: 'x', onPressed: () {}, grouped: true),
      ),
    ));
    expect(
        tester.widget<GlassSurface>(find.byType(GlassSurface)).grouped, isTrue);
  });
}
