import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/osd_dialog.dart';

Future<void> _open(WidgetTester tester, Widget dialog) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => dialog,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lays out title, content and actions on the OSD material',
      (tester) async {
    await _open(
      tester,
      OsdDialog(
        title: const Text('Title'),
        content: const Text('Body'),
        actions: [TextButton(onPressed: () {}, child: const Text('OK'))],
      ),
    );

    expect(find.text('Title'), findsOneWidget);
    expect(find.text('Body'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);

    final surface = tester.widget<GlassSurface>(
      find.ancestor(of: find.text('Body'), matching: find.byType(GlassSurface)),
    );
    expect(surface.blurSigma, DepthTokens.osdBlurSigma);
    expect(surface.shadows, DepthTokens.osdShadowPanel);
    expect(
      surface.borderRadius,
      const BorderRadius.all(Radius.circular(DepthTokens.radiusOsdSheet)),
    );
  });

  testWidgets('the dialog paints no Material of its own', (tester) async {
    await _open(
      tester,
      const OsdDialog(title: Text('Title'), content: Text('Body')),
    );

    final dialog = tester.widget<Dialog>(find.byType(Dialog));
    expect(dialog.backgroundColor, Colors.transparent);
    expect(dialog.surfaceTintColor, Colors.transparent);
    expect(dialog.elevation, 0);
  });

  testWidgets('title and content default to OSD text colours', (tester) async {
    await _open(
      tester,
      const OsdDialog(title: Text('Title'), content: Text('Body')),
    );

    expect(
      DefaultTextStyle.of(tester.element(find.text('Title'))).style.color,
      AppColors.textPrimary,
    );
    expect(
      DefaultTextStyle.of(tester.element(find.text('Body'))).style.color,
      AppColors.textSecondary,
    );
  });

  testWidgets('a maxFinite-width list sizes as it did under AlertDialog',
      (tester) async {
    await _open(
      tester,
      OsdDialog(
        title: const Text('Title'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: const [ListTile(title: Text('Row'))],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Row'), findsOneWidget);
  });
}
