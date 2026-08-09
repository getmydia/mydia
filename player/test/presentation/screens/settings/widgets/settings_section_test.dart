import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/presentation/screens/settings/widgets/settings_row.dart';
import 'package:player/presentation/screens/settings/widgets/settings_section.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: ListView(children: [child]))),
  );
  await tester.pump();
}

void main() {
  testWidgets('SettingsSection renders its label above its card',
      (tester) async {
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

  testWidgets('SettingsSection uppercases its label for the eyebrow style',
      (tester) async {
    await _pump(
      tester,
      const SettingsSection(label: 'Playback', children: [SizedBox()]),
    );

    final label = tester.widget<Text>(find.text('Playback'));
    expect(label.style?.letterSpacing, greaterThan(0));
  });

  testWidgets(
      'SettingsCard draws a divider between rows but not after the last',
      (tester) async {
    await _pump(
      tester,
      SettingsCard(
        children: [
          SettingsRow.navigation(
              icon: Icons.looks_one, title: 'One', onTap: () {}),
          SettingsRow.navigation(
              icon: Icons.looks_two, title: 'Two', onTap: () {}),
          SettingsRow.navigation(
              icon: Icons.looks_3, title: 'Three', onTap: () {}),
        ],
      ),
    );

    expect(find.byType(Divider), findsNWidgets(2));
  });

  testWidgets('SettingsCard uses the shared card radius', (tester) async {
    await _pump(
      tester,
      const SettingsCard(children: [SizedBox(height: 40)]),
    );

    final clip = tester.widget<ClipRRect>(find.byType(ClipRRect).first);
    expect(
      clip.borderRadius,
      BorderRadius.circular(AppTheme.radiusCard),
    );
  });
}
