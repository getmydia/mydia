import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/presentation/widgets/glass/glass_dialog.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

Widget _host() => MaterialApp(
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
  tearDown(() => LiquidGlassSupport.debugPlatformOverride = null);

  testWidgets('iOS and macOS: laid out on modal glass', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    await tester.pumpWidget(_host());
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

  testWidgets('elsewhere it is the AlertDialog it replaced', (tester) async {
    LiquidGlassSupport.debugPlatformOverride = false;
    await tester.pumpWidget(_host());
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect((dialog.title! as Text).data, 'Remove account?');
    expect(dialog.actions, hasLength(2));
  });
  testWidgets('iOS and macOS: tall content scrolls instead of overflowing',
      (tester) async {
    LiquidGlassSupport.debugPlatformOverride = true;
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
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
