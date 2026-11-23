import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
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

  testWidgets('header is sentence styled', (tester) async {
    await _pump(
      tester,
      const SettingsSection(label: 'Playback', children: [SizedBox()]),
    );

    final style = tester.widget<Text>(find.text('Playback')).style;
    expect(style?.fontSize, 13);
    expect(style?.fontWeight, FontWeight.w600);
    expect(style?.letterSpacing ?? 0, 0);
  });

  testWidgets('footer renders under the card', (tester) async {
    await _pump(
      tester,
      const SettingsSection(
        label: 'Skipping',
        footer: 'When off, a skip button appears instead.',
        children: [SizedBox(height: 40)],
      ),
    );

    final footer = find.text('When off, a skip button appears instead.');
    expect(footer, findsOneWidget);
    expect(
      tester.getTopLeft(footer).dy,
      greaterThan(tester.getBottomLeft(find.byType(SettingsCard)).dy),
    );
  });

  testWidgets('no footer, no extra text', (tester) async {
    await _pump(
      tester,
      const SettingsSection(label: 'Skipping', children: [Text('Row')]),
    );

    expect(find.byType(Text), findsNWidgets(2));
  });

  testWidgets('card dividers are inset 16', (tester) async {
    await _pump(
      tester,
      const SettingsCard(
        children: [SizedBox(height: 40), SizedBox(height: 40)],
      ),
    );

    expect(tester.widget<Divider>(find.byType(Divider)).indent, 16);
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

  testWidgets('SettingsCard uses the settings card radius', (tester) async {
    await _pump(tester, const SettingsCard(children: [SizedBox(height: 40)]));

    final clip = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
    expect(
      clip.borderRadius,
      BorderRadius.circular(AppTheme.radiusSettingsCard),
    );
  });
}
