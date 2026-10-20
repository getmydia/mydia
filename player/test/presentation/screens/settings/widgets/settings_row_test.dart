import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/settings/widgets/settings_row.dart';

Future<void> _pump(WidgetTester tester, Widget row) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: ListView(children: [row]))),
  );
  await tester.pump();
}

/// The focus node FocusHighlight owns for [title]'s row. Asked from the ring,
/// which sits directly under the detector's Focus, so the lookup does not land
/// on the InkWell's own (non-focusable) node.
FocusNode _node(WidgetTester tester, String title) {
  final ring = find.ancestor(
    of: find.text(title),
    matching: find.byKey(FocusHighlight.ringKey),
  );
  return Focus.of(tester.element(ring.first));
}

void main() {
  _focusTests();
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

    testWidgets('draws a status dot before the subtitle when given a colour',
        (tester) async {
      await _pump(
        tester,
        SettingsRow.navigation(
          icon: Icons.lan_outlined,
          title: 'Connection details',
          subtitle: 'Connected through a relay',
          subtitleDotColor: const Color(0xFFE8722C),
          onTap: () {},
        ),
      );

      final dot = tester.widget<Container>(
        find.byKey(const Key('settings-row-status-dot')),
      );
      final decoration = dot.decoration as BoxDecoration;

      expect(decoration.color, const Color(0xFFE8722C));
      expect(find.text('Connected through a relay'), findsOneWidget);
    });

    testWidgets('draws no dot when no colour is given', (tester) async {
      await _pump(
        tester,
        SettingsRow.navigation(
          icon: Icons.lan_outlined,
          title: 'Connection details',
          subtitle: 'Connected through a relay',
          onTap: () {},
        ),
      );

      expect(find.byKey(const Key('settings-row-status-dot')), findsNothing);
    });

    testWidgets('draws no dot when there is no subtitle to sit beside',
        (tester) async {
      await _pump(
        tester,
        SettingsRow.navigation(
          icon: Icons.lan_outlined,
          title: 'Connection details',
          subtitleDotColor: const Color(0xFFE8722C),
          onTap: () {},
        ),
      );

      expect(find.byKey(const Key('settings-row-status-dot')), findsNothing);
    });

    testWidgets('a null onTap dims the row', (tester) async {
      await _pump(
        tester,
        const SettingsRow.navigation(
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

void _focusTests() {
  group('SettingsRow focus', () {
    testWidgets('Enter on a navigation row calls onTap', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        SettingsRow.navigation(
          icon: Icons.hd,
          title: 'Default quality',
          onTap: () => taps++,
        ),
      );
      _node(tester, 'Default quality').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(taps, 2);
    });

    testWidgets('a navigation row with null onTap is not focusable',
        (tester) async {
      await _pump(
        tester,
        const SettingsRow.navigation(
          icon: Icons.hd,
          title: 'Default quality',
          onTap: null,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_node(tester, 'Default quality').hasFocus, isFalse);
    });

    testWidgets('key activation flips a toggle row', (tester) async {
      bool? received;
      await _pump(
        tester,
        SettingsRow.toggle(
          icon: Icons.fast_forward,
          title: 'Skip intros',
          value: false,
          onChanged: (v) => received = v,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(received, isTrue);
    });

    testWidgets('the Switch is not a separate traversal stop', (tester) async {
      await _pump(
        tester,
        Column(
          children: [
            SettingsRow.toggle(
              icon: Icons.fast_forward,
              title: 'First',
              value: false,
              onChanged: (_) {},
            ),
            SettingsRow.navigation(
              icon: Icons.hd,
              title: 'Second',
              onTap: () {},
            ),
          ],
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final first = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final second = FocusManager.instance.primaryFocus;
      expect(second, isNot(first));
      expect(
        find.descendant(
          of: find.ancestor(
              of: find.text('Second'), matching: find.byType(FocusHighlight)),
          matching: find.text('Second'),
        ),
        findsOneWidget,
      );
      expect(
        _node(tester, 'Second').hasPrimaryFocus,
        isTrue,
      );
    });

    testWidgets('a disabled toggle row is not focusable', (tester) async {
      await _pump(
        tester,
        const SettingsRow.toggle(
          icon: Icons.fast_forward,
          title: 'Skip intros',
          value: false,
          onChanged: null,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_node(tester, 'Skip intros').hasFocus, isFalse);
    });
  });
}
