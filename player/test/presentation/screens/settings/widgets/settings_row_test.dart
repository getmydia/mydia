import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/settings/widgets/settings_row.dart';

Future<void> _pump(WidgetTester tester, Widget row) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ListView(children: [row])),
    ),
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
    testWidgets('shows its title, subtitle, and chevron', (tester) async {
      await _pump(
        tester,
        SettingsRow.navigation(
          title: 'Default quality',
          subtitle: 'Used when a title has no saved preference',
          onTap: () {},
        ),
      );

      expect(find.text('Default quality'), findsOneWidget);
      expect(
        find.text('Used when a title has no saved preference'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('draws a status dot before the subtitle when given a colour', (
      tester,
    ) async {
      await _pump(
        tester,
        SettingsRow.navigation(
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
          title: 'Connection details',
          subtitle: 'Connected through a relay',
          onTap: () {},
        ),
      );

      expect(find.byKey(const Key('settings-row-status-dot')), findsNothing);
    });

    testWidgets('draws no dot when there is no subtitle to sit beside', (
      tester,
    ) async {
      await _pump(
        tester,
        SettingsRow.navigation(
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
        const SettingsRow.navigation(title: 'Default quality', onTap: null),
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
        SettingsRow.navigation(title: 'Paired devices', onTap: () => taps++),
      );

      await tester.tap(find.text('Paired devices'));
      await tester.pump();

      expect(taps, 1);
    });
  });

  group('SettingsRow restyle', () {
    testWidgets('rows are at least 52 tall', (tester) async {
      for (final row in <Widget>[
        SettingsRow.navigation(title: 'Nav', onTap: () {}),
        SettingsRow.toggle(title: 'Tog', value: false, onChanged: (_) {}),
        SettingsRow.action(title: 'Act', onTap: () {}),
      ]) {
        await _pump(tester, row);
        expect(
          tester.getSize(find.byType(SettingsRow)).height,
          greaterThanOrEqualTo(52),
        );
      }
    });
  });

  group('SettingsRow switch size', () {
    testWidgets('the switch lays out 40x24 and a title-only toggle is 52', (
      tester,
    ) async {
      await _pump(
        tester,
        SettingsRow.toggle(title: 'Tog', value: false, onChanged: (_) {}),
      );
      expect(
        tester.getSize(find.byKey(const Key('settings-row-switch-box'))),
        const Size(40, 24),
      );
      expect(tester.getSize(find.byType(SettingsRow)).height, 52);
    });

    testWidgets('a long select value is ellipsized within 200', (tester) async {
      await _pump(
        tester,
        SettingsRow.select(
          title: 'Default quality',
          value: 'A very long value ' * 10,
          onTap: () {},
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester
            .getSize(find.byKey(const Key('settings-row-select-value')))
            .width,
        lessThanOrEqualTo(200),
      );
    });
  });

  group('SettingsRow.select', () {
    testWidgets('the value is 30 tall and grows with large text', (
      tester,
    ) async {
      Size valueSize() =>
          tester.getSize(find.byKey(const Key('settings-row-select-value')));
      final row = SettingsRow.select(
        title: 'Default quality',
        value: 'Auto',
        onTap: () {},
      );

      await _pump(tester, row);
      expect(valueSize().height, 30);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(3)),
            child: Scaffold(body: ListView(children: [row])),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(valueSize().height, greaterThan(30));
    });

    testWidgets('a null value draws no value button', (tester) async {
      await _pump(
        tester,
        const SettingsRow.select(
          title: 'Default quality',
          value: null,
          onTap: null,
        ),
      );
      expect(find.byKey(const Key('settings-row-select-value')), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });

    testWidgets('shows value and chevron-down', (tester) async {
      await _pump(
        tester,
        SettingsRow.select(
          title: 'Default quality',
          value: 'Auto',
          onTap: () {},
        ),
      );
      expect(find.text('Auto'), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(
        find.byKey(const Key('settings-row-select-value')),
        findsOneWidget,
      );
    });

    testWidgets('activates by tap and by Enter', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        SettingsRow.select(
          title: 'Default quality',
          value: 'Auto',
          onTap: () => taps++,
        ),
      );
      await tester.tap(find.text('Default quality'));
      await tester.pump();
      _node(tester, 'Default quality').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(taps, 2);
    });

    testWidgets('value button is not a second focus stop', (tester) async {
      await _pump(
        tester,
        SettingsRow.select(
          title: 'Default quality',
          value: 'Auto',
          onTap: () {},
        ),
      );
      final scope = FocusScope.of(
        tester.element(find.byKey(const Key('settings-row-select-value'))),
      );
      final stops = scope.traversalDescendants.where((n) => n.canRequestFocus);
      expect(stops.length, 1);
      expect(
        stops.single,
        _node(tester, 'Default quality'),
        reason: 'the only stop is the row itself',
      );
    });

    testWidgets('null onTap dims select', (tester) async {
      await _pump(
        tester,
        const SettingsRow.select(
          title: 'Default quality',
          value: 'Auto',
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
      expect(opacity.opacity, 0.45);
    });
  });

  group('SettingsRow.toggle', () {
    testWidgets('reports its value and reports changes', (tester) async {
      bool? received;
      await _pump(
        tester,
        SettingsRow.toggle(
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
          title: 'Skip intros and credits',
          value: false,
          onChanged: null,
        ),
      );

      expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
    });
  });

  group('SettingsRow.action', () {
    testWidgets('renders a trailing widget instead of a chevron', (
      tester,
    ) async {
      await _pump(
        tester,
        SettingsRow.action(
          title: 'Check for updates',
          trailing: const Text('Check now'),
          onTap: () {},
        ),
      );

      expect(find.text('Check now'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('a danger row tints its title with the error colour', (
      tester,
    ) async {
      await _pump(
        tester,
        SettingsRow.action(title: 'Sign out', danger: true, onTap: () {}),
      );

      final context = tester.element(find.text('Sign out'));
      final title = tester.widget<Text>(find.text('Sign out'));

      expect(title.style?.color, Theme.of(context).colorScheme.error);
    });

    testWidgets('a null onTap makes the row inert but not dimmed', (
      tester,
    ) async {
      // Diagnostics is built almost entirely from informational action rows.
      // Dimming those would make a healthy screen look broken, which is why
      // `.action` and `.navigation` treat a null onTap differently.
      await _pump(
        tester,
        const SettingsRow.action(title: 'Check for updates', onTap: null),
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
        SettingsRow.navigation(title: 'Default quality', onTap: () => taps++),
      );
      _node(tester, 'Default quality').requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(taps, 2);
    });

    testWidgets('a navigation row with null onTap is not focusable', (
      tester,
    ) async {
      await _pump(
        tester,
        const SettingsRow.navigation(title: 'Default quality', onTap: null),
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
            SettingsRow.toggle(title: 'First', value: false, onChanged: (_) {}),
            SettingsRow.navigation(title: 'Second', onTap: () {}),
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
            of: find.text('Second'),
            matching: find.byType(FocusHighlight),
          ),
          matching: find.text('Second'),
        ),
        findsOneWidget,
      );
      expect(_node(tester, 'Second').hasPrimaryFocus, isTrue);
    });

    testWidgets('a disabled toggle row is not focusable', (tester) async {
      await _pump(
        tester,
        const SettingsRow.toggle(
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
