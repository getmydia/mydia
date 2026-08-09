import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/settings/widgets/settings_row.dart';

Future<void> _pump(WidgetTester tester, Widget row) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: ListView(children: [row]))),
  );
  await tester.pump();
}

void main() {
  group('SettingsRow.navigation', () {
    testWidgets('shows its title, subtitle, and trailing value',
        (tester) async {
      await _pump(
        tester,
        SettingsRow.navigation(
          icon: Icons.hd,
          title: 'Default quality',
          subtitle: 'Used when a title has no saved preference',
          value: '1080p',
          onTap: () {},
        ),
      );

      expect(find.text('Default quality'), findsOneWidget);
      expect(find.text('Used when a title has no saved preference'),
          findsOneWidget);
      expect(find.text('1080p'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('a null onTap dims the row', (tester) async {
      await _pump(
        tester,
        SettingsRow.navigation(
          icon: Icons.hd,
          title: 'Default quality',
          onTap: null,
        ),
      );

      final opacity = tester.widget<Opacity>(
        find
            .descendant(
              of: find.byType(SettingsRow),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(opacity.opacity, lessThan(1.0));
    });

    testWidgets('calls onTap when tapped', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        SettingsRow.navigation(
          icon: Icons.devices,
          title: 'Paired devices',
          onTap: () => taps++,
        ),
      );

      await tester.tap(find.text('Paired devices'));
      await tester.pump();

      expect(taps, 1);
    });
  });

  group('SettingsRow.toggle', () {
    testWidgets('reports its value and reports changes', (tester) async {
      bool? received;
      await _pump(
        tester,
        SettingsRow.toggle(
          icon: Icons.fast_forward,
          title: 'Skip intros and credits',
          value: false,
          onChanged: (next) => received = next,
        ),
      );

      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      await tester.tap(find.byType(Switch));
      await tester.pump();

      expect(received, isTrue);
    });

    testWidgets('a null onChanged disables the switch', (tester) async {
      await _pump(
        tester,
        const SettingsRow.toggle(
          icon: Icons.fast_forward,
          title: 'Skip intros and credits',
          value: false,
          onChanged: null,
        ),
      );

      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    });
  });

  group('SettingsRow.action', () {
    testWidgets('renders a trailing widget instead of a chevron',
        (tester) async {
      await _pump(
        tester,
        SettingsRow.action(
          icon: Icons.refresh,
          title: 'Check for updates',
          trailing: const Text('Check now'),
          onTap: () {},
        ),
      );

      expect(find.text('Check now'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('a danger row tints its title with the error colour',
        (tester) async {
      await _pump(
        tester,
        SettingsRow.action(
          icon: Icons.logout,
          title: 'Sign out',
          danger: true,
          onTap: () {},
        ),
      );

      final context = tester.element(find.text('Sign out'));
      final title = tester.widget<Text>(find.text('Sign out'));

      expect(title.style?.color, Theme.of(context).colorScheme.error);
    });

    testWidgets('a null onTap makes the row inert but not dimmed',
        (tester) async {
      // Diagnostics is built almost entirely from informational action rows.
      // Dimming those would make a healthy screen look broken, which is why
      // `.action` and `.navigation` treat a null onTap differently.
      await _pump(
        tester,
        const SettingsRow.action(
          icon: Icons.refresh,
          title: 'Check for updates',
          onTap: null,
        ),
      );

      final inkWell = tester.widget<InkWell>(find.byType(InkWell));
      expect(inkWell.onTap, isNull);

      final opacity = tester.widget<Opacity>(
        find
            .descendant(
              of: find.byType(SettingsRow),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(opacity.opacity, 1.0);
    });
  });
}
