import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/glass_dialog.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

ThemeData _theme({required bool liquid}) =>
    AppTheme.build(Palettes.projectionBooth, liquid: liquid);

Widget _host({required bool liquid}) => MaterialApp(
      theme: _theme(liquid: liquid),
      home: Scaffold(
        body: GlassDialog(
          icon: const Icon(Icons.warning_rounded),
          title: const Text('Remove account?'),
          content: const Text('This signs you out.'),
          actions: [
            TextButton(onPressed: () {}, child: const Text('Cancel')),
            FilledButton(onPressed: () {}, child: const Text('Remove')),
          ],
        ),
      ),
    );

void main() {
  testWidgets('Liquid Glass: laid out on modal glass', (tester) async {
    await tester.pumpWidget(_host(liquid: true));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(GlassSurface), findsOneWidget);
    for (final text in [
      'Remove account?',
      'This signs you out.',
      'Cancel',
      'Remove',
    ]) {
      expect(find.text(text), findsOneWidget);
    }
    expect(find.byIcon(Icons.warning_rounded), findsOneWidget);
  });

  testWidgets('Frosted: it is the AlertDialog it replaced', (tester) async {
    await tester.pumpWidget(_host(liquid: false));
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect((dialog.title! as Text).data, 'Remove account?');
    expect(dialog.actions, hasLength(2));
  });
  testWidgets('Liquid Glass: tall content scrolls instead of overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: _theme(liquid: true),
      home: Scaffold(
        body: Center(
          child: GlassDialog(
            title: const Text('Logs'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [for (var i = 0; i < 60; i++) Text('Row $i')],
            ),
            actions: [TextButton(onPressed: () {}, child: const Text('OK'))],
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });
}
