import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/controls/app_switch.dart';

Widget _host(Widget child, {bool liquid = false}) => MaterialApp(
  theme: AppTheme.build(Palettes.oledBlack, liquid: liquid),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('Frosted row uses AppSwitch, toggles on tap, one focus stop', (
    tester,
  ) async {
    var value = false;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => AppSwitchTile(
            key: const Key('row'),
            value: value,
            onChanged: (v) => setState(() => value = v),
            title: const Text('Sync now'),
            subtitle: const Text('Every hour'),
          ),
        ),
      ),
    );
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.byKey(AppSwitch.trackKey), findsOneWidget);

    await tester.tap(find.text('Sync now'));
    await tester.pump();
    expect(value, isTrue);

    await tester.tap(find.byKey(AppSwitch.trackKey));
    await tester.pump();
    expect(value, isFalse);

    final focusable = FocusManager.instance.rootScope.descendants.where(
      (n) => n.canRequestFocus && !n.skipTraversal && n is! FocusScopeNode,
    );
    expect(focusable, hasLength(1));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(value, isTrue);

    expect(
      tester.getSemantics(find.byKey(const Key('row'))),
      matchesSemantics(
        label: 'Sync now\nEvery hour',
        isToggled: true,
        hasToggledState: true,
        hasSelectedState: true,
        isEnabled: true,
        hasEnabledState: true,
        isFocusable: true,
        isFocused: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
  });

  testWidgets('null onChanged disables the row', (tester) async {
    await tester.pumpWidget(
      _host(
        const AppSwitchTile(
          value: true,
          onChanged: null,
          title: Text('Sync now'),
        ),
      ),
    );
    expect(tester.widget<ListTile>(find.byType(ListTile)).enabled, isFalse);
    await tester.tap(find.text('Sync now'));
    await tester.pump();
  });

  testWidgets('Liquid keeps the stock SwitchListTile', (tester) async {
    await tester.pumpWidget(
      _host(
        AppSwitchTile(
          value: true,
          onChanged: (_) {},
          title: const Text('Sync now'),
        ),
        liquid: true,
      ),
    );
    expect(find.byType(SwitchListTile), findsOneWidget);
  });
}
