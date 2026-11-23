import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/screens/settings/widgets/settings_row.dart';
import 'package:player/presentation/screens/settings/widgets/settings_section.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ListView(children: [child])),
    ),
  );
  await tester.pump();
}

Future<void> _pumpThemed(
  WidgetTester tester, {
  required bool liquid,
  required Widget child,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(Palettes.projectionBooth, liquid: liquid),
      home: Scaffold(body: ListView(children: [child])),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('SettingsSection renders its label above its card', (
    tester,
  ) async {
    await _pump(
      tester,
      SettingsSection(
        label: 'Playback',
        children: [
          SettingsRow.navigation(
            icon: Icons.hd,
            title: 'Default quality',
            onTap: () {},
          ),
        ],
      ),
    );

    expect(find.text('Playback'), findsOneWidget);
    expect(find.byType(SettingsCard), findsOneWidget);

    final labelY = tester.getTopLeft(find.text('Playback')).dy;
    final cardY = tester.getTopLeft(find.byType(SettingsCard)).dy;
    expect(labelY, lessThan(cardY));
  });

  testWidgets('eyebrow is 13/600 textSecondary without tracking in Frosted', (
    tester,
  ) async {
    await _pumpThemed(
      tester,
      liquid: false,
      child: const SettingsSection(label: 'Playback', children: [SizedBox()]),
    );

    final label = tester.widget<Text>(find.text('Playback'));
    expect(label.data, 'Playback');
    expect(label.style?.fontSize, 13);
    expect(label.style?.fontWeight, FontWeight.w600);
    expect(label.style?.letterSpacing, anyOf(isNull, 0));
    expect(label.style?.color, Palettes.projectionBooth.textSecondary);
  });

  testWidgets('eyebrow keeps 11/600 textDisabled with tracking in Liquid', (
    tester,
  ) async {
    await _pumpThemed(
      tester,
      liquid: true,
      child: const SettingsSection(label: 'Playback', children: [SizedBox()]),
    );

    final label = tester.widget<Text>(find.text('Playback'));
    expect(label.style?.fontSize, 11);
    expect(label.style?.fontWeight, FontWeight.w600);
    expect(label.style?.letterSpacing, 1.2);
    expect(label.style?.color, Palettes.projectionBooth.textDisabled);
  });

  testWidgets(
    'SettingsCard draws a divider between rows but not after the last',
    (tester) async {
      await _pump(
        tester,
        SettingsCard(
          children: [
            SettingsRow.navigation(
              icon: Icons.looks_one,
              title: 'One',
              onTap: () {},
            ),
            SettingsRow.navigation(
              icon: Icons.looks_two,
              title: 'Two',
              onTap: () {},
            ),
            SettingsRow.navigation(
              icon: Icons.looks_3,
              title: 'Three',
              onTap: () {},
            ),
          ],
        ),
      );

      expect(find.byType(Divider), findsNWidgets(2));
    },
  );

  testWidgets('SettingsCard uses the shared card radius', (tester) async {
    await _pump(tester, const SettingsCard(children: [SizedBox(height: 40)]));

    final clip = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
    expect(clip.borderRadius, BorderRadius.circular(AppTheme.radiusCard));
  });
}
