import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/screens/settings/widgets/settings_choice_grid.dart';

List<SettingsChoice<int>> _choices() => [
  for (var i = 0; i < 4; i++)
    SettingsChoice<int>(
      value: i,
      label: 'Option $i',
      preview: const SizedBox.expand(),
    ),
];

Future<void> _pump(
  WidgetTester tester, {
  required ValueChanged<int> onSelected,
  int selected = 0,
  double width = 800,
  Widget? below,
  SettingsChoiceLayout layout = SettingsChoiceLayout.stacked,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SettingsChoiceGrid<int>(
                  label: 'Theme',
                  choices: _choices(),
                  selected: selected,
                  onSelected: onSelected,
                  layout: layout,
                ),
                ?below,
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Border _border(WidgetTester tester, int index) {
  final box = find.descendant(
    of: find.byKey(Key('settings-choice-$index')),
    matching: find.byType(DecoratedBox),
  );
  for (final e in box.evaluate()) {
    final d = (e.widget as DecoratedBox).decoration;
    if (d is BoxDecoration && d.border is Border) return d.border! as Border;
  }
  throw StateError('no bordered DecoratedBox in option $index');
}

void main() {
  testWidgets('tap selects', (tester) async {
    int? got;
    await _pump(tester, onSelected: (v) => got = v);
    await tester.tap(find.byKey(const Key('settings-choice-2')));
    expect(got, 2);
  });

  testWidgets('selected option has a primary ring', (tester) async {
    await _pump(tester, onSelected: (_) {}, selected: 1);
    final primary = tester
        .element(find.byKey(const Key('settings-choice-1')))
        .palette
        .primary;
    final sel = _border(tester, 1).top;
    expect(sel.color, primary);
    expect(sel.width, 2);
    expect(_border(tester, 0).top.width, 1);
    expect(_border(tester, 2).top.width, 1);
  });

  testWidgets('radio semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, onSelected: (_) {});
    expect(
      tester.getSemantics(find.byKey(const Key('settings-choice-0'))),
      matchesSemantics(
        label: 'Option 0',
        isInMutuallyExclusiveGroup: true,
        hasCheckedState: true,
        isChecked: true,
        hasTapAction: true,
        hasFocusAction: true,
        isFocusable: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('arrow keys move between options and Enter selects', (
    tester,
  ) async {
    int? got;
    await _pump(tester, onSelected: (v) => got = v);
    _focusOption(tester, 0).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(got, 1);
  });

  testWidgets('down leaves the grid', (tester) async {
    final buttonFocus = FocusNode();
    addTearDown(buttonFocus.dispose);
    await _pump(
      tester,
      onSelected: (_) {},
      below: TextButton(
        focusNode: buttonFocus,
        onPressed: () {},
        child: const Text('Below'),
      ),
    );
    _focusOption(tester, 3).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(buttonFocus.hasFocus, isTrue);
  });

  testWidgets('wraps to two columns when narrow', (tester) async {
    await _pump(tester, onSelected: (_) {}, width: 360);
    final y0 = tester.getTopLeft(find.byKey(const Key('settings-choice-0'))).dy;
    final y2 = tester.getTopLeft(find.byKey(const Key('settings-choice-2'))).dy;
    expect(y2, greaterThan(y0));
  });

  testWidgets('inline layout shows the description', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsChoiceGrid<int>(
            label: 'Material',
            columns: 2,
            layout: SettingsChoiceLayout.inline,
            choices: const [
              SettingsChoice(
                value: 0,
                label: 'Glass',
                description: 'Frosted',
                preview: SizedBox.expand(),
              ),
              SettingsChoice(
                value: 1,
                label: 'Solid',
                preview: SizedBox.expand(),
              ),
            ],
            selected: 0,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('Frosted'), findsOneWidget);
  });
}

FocusNode _focusOption(WidgetTester tester, int index) {
  final element = tester.element(
    find
        .descendant(
          of: find.byKey(Key('settings-choice-$index')),
          matching: find.byType(InkWell),
        )
        .first,
  );
  // The nearest focusable ancestor of the InkWell is FocusHighlight's node.
  return Focus.of(element);
}
