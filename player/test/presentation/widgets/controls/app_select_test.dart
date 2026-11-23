import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/controls/app_select.dart';

final _palette = Palettes.projectionBooth;

const _items = [
  AppSelectItem(value: 'a', label: 'Alpha', key: ValueKey('item-a')),
  AppSelectItem(value: 'b', label: 'Bravo', key: ValueKey('item-b')),
  AppSelectItem(value: 'c', label: 'Charlie', key: ValueKey('item-c')),
];

/// Hosts the select above a plain button, so traversal has somewhere to go.
Widget _host(Widget control) {
  // MaterialApp, not a bare Theme: it installs the default shortcuts that
  // map Tab, the arrows and Escape.
  return MaterialApp(
    theme: AppTheme.build(_palette, liquid: false),
    home: Material(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            control,
            TextButton(
              key: const Key('below'),
              onPressed: () {},
              child: const Text('Below'),
            ),
          ],
        ),
      ),
    ),
  );
}

/// A stateful harness that records every change and applies it.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.initial,
    required this.log,
    this.placeholder,
    this.enabled = true,
  });

  final String? initial;
  final List<String> log;
  final String? placeholder;
  final bool enabled;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late String? _value = widget.initial;

  @override
  Widget build(BuildContext context) => AppSelect<String>(
    key: const Key('select'),
    items: _items,
    value: _value,
    placeholder: widget.placeholder,
    enabled: widget.enabled,
    semanticLabel: 'Letter',
    onChanged: (v) {
      widget.log.add(v);
      setState(() => _value = v);
    },
  );
}

bool _focusInside(WidgetTester tester, Finder finder) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final target = tester.element(finder);
  if (context == target) return true;
  var inside = false;
  context.visitAncestorElements((e) {
    if (e == target) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

Finder get _menuCheck => find.byKey(AppSelect.checkKey);

void main() {
  testWidgets('field look', (tester) async {
    await tester.pumpWidget(_host(const _Harness(initial: 'b', log: [])));

    final field = find.byKey(AppSelect.fieldKey);
    expect(tester.getSize(field).height, 40);
    final decoration =
        tester.widget<Container>(field).decoration! as BoxDecoration;
    expect(decoration.color, _palette.surfaceLow);
    expect(decoration.borderRadius, BorderRadius.circular(10));
    expect((decoration.border! as Border).top.color, const Color(0x24FFFFFF));
    expect(
      find.descendant(of: field, matching: find.text('Bravo')),
      findsOneWidget,
    );
    final chevron = tester.widget<Icon>(find.byKey(AppSelect.chevronKey));
    expect(chevron.icon, Icons.unfold_more_rounded);
  });

  testWidgets('opens the menu under the field with the value checked', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(_host(_Harness(initial: 'b', log: log)));

    await tester.tap(find.byKey(const Key('select')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('item-a')), findsOneWidget);
    expect(_menuCheck, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('item-b')),
        matching: _menuCheck,
      ),
      findsOneWidget,
    );
    final fieldBottom = tester.getBottomLeft(find.byKey(AppSelect.fieldKey)).dy;
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('item-a'))).dy,
      greaterThanOrEqualTo(fieldBottom),
    );

    await tester.tap(find.byKey(const ValueKey('item-c')));
    await tester.pumpAndSettle();

    expect(log, ['c']);
    expect(find.byKey(const ValueKey('item-a')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(AppSelect.fieldKey),
        matching: find.text('Charlie'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('picking the current value does not call onChanged', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(_host(_Harness(initial: 'b', log: log)));

    await tester.tap(find.byKey(const Key('select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('item-b')));
    await tester.pumpAndSettle();

    expect(log, isEmpty);
    expect(find.byKey(const ValueKey('item-a')), findsNothing);
  });

  group('D-pad', () {
    testWidgets('one focus stop; Select opens; arrows move in the menu', (
      tester,
    ) async {
      final log = <String>[];
      await tester.pumpWidget(_host(_Harness(initial: 'a', log: log)));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusInside(tester, find.byKey(const Key('select'))), isTrue);

      // One stop: the next Tab leaves the select for the button below.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_focusInside(tester, find.byKey(const Key('below'))), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(_focusInside(tester, find.byKey(const Key('select'))), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('item-a')), findsOneWidget);
      // The checked row takes focus on open.
      expect(
        _focusInside(tester, find.byKey(const ValueKey('item-a'))),
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        _focusInside(tester, find.byKey(const ValueKey('item-b'))),
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        _focusInside(tester, find.byKey(const ValueKey('item-c'))),
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(log, ['c']);
      expect(find.byKey(const ValueKey('item-a')), findsNothing);
      expect(_focusInside(tester, find.byKey(const Key('select'))), isTrue);
    });

    for (final back in [LogicalKeyboardKey.goBack, LogicalKeyboardKey.escape]) {
      testWidgets('${back.debugName} closes the menu and focus returns', (
        tester,
      ) async {
        final log = <String>[];
        await tester.pumpWidget(_host(_Harness(initial: 'a', log: log)));

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('item-a')), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();

        // The Android TV remote's Back arrives as goBack, which has no
        // physical key in the simulator's Android table; send it as web.
        await tester.sendKeyEvent(
          back,
          platform: back == LogicalKeyboardKey.goBack ? 'web' : 'android',
          physicalKey: back == LogicalKeyboardKey.goBack
              ? PhysicalKeyboardKey.browserBack
              : null,
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('item-a')), findsNothing);
        expect(log, isEmpty);
        expect(_focusInside(tester, find.byKey(const Key('select'))), isTrue);
      });
    }
  });

  testWidgets('value missing from items shows the placeholder', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(
      _host(_Harness(initial: 'zzz', log: log, placeholder: 'Pick one')),
    );
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(AppSelect.fieldKey),
        matching: find.text('Pick one'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('select')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('item-a')), findsOneWidget);
    expect(_menuCheck, findsNothing);
  });

  testWidgets('value missing and no placeholder renders empty', (tester) async {
    await tester.pumpWidget(_host(const _Harness(initial: null, log: [])));
    expect(tester.takeException(), isNull);
    for (final item in _items) {
      expect(find.text(item.label), findsNothing);
    }
  });

  testWidgets('disabled: no focus, no menu, dimmed label', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(
      _host(_Harness(initial: 'a', log: log, enabled: false)),
    );

    await tester.tap(find.byKey(const Key('select')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('item-b')), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_focusInside(tester, find.byKey(const Key('select'))), isFalse);
    expect(_focusInside(tester, find.byKey(const Key('below'))), isTrue);

    final label = tester.widget<Text>(
      find.descendant(
        of: find.byKey(AppSelect.fieldKey),
        matching: find.text('Alpha'),
      ),
    );
    expect(label.style!.color!.a, closeTo(AppSelect.disabledOpacity, 0.01));
    expect(log, isEmpty);
  });

  testWidgets('a pick resolves against the rows the menu showed', (
    tester,
  ) async {
    final log = <String>[];
    var items = _items;
    late StateSetter rebuild;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return AppSelect<String>(
              key: const Key('select'),
              items: items,
              value: 'a',
              onChanged: log.add,
            );
          },
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('select')));
    await tester.pumpAndSettle();
    // The field's items reorder while the menu is open.
    rebuild(() => items = _items.reversed.toList());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('item-c')));
    await tester.pumpAndSettle();

    expect(log, ['c']);
  });

  testWidgets('a nullable value type keeps null as a real choice', (
    tester,
  ) async {
    final log = <int?>[];
    int? value = 1;
    await tester.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => AppSelect<int?>(
            key: const Key('select'),
            items: const [
              AppSelectItem(value: null, label: 'Any', key: ValueKey('any')),
              AppSelectItem(value: 1, label: 'One', key: ValueKey('one')),
            ],
            value: value,
            onChanged: (v) {
              log.add(v);
              setState(() => value = v);
            },
          ),
        ),
      ),
    );

    // Dismissing answers nothing.
    await tester.tap(find.byKey(const Key('select')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(log, isEmpty);

    await tester.tap(find.byKey(const Key('select')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('any')));
    await tester.pumpAndSettle();
    expect(log, [null]);
  });

  testWidgets('semantics: a button named by its label and value', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(const _Harness(initial: 'b', log: [])));
    expect(
      tester.getSemantics(find.byKey(const Key('select'))),
      matchesSemantics(
        label: 'Letter',
        value: 'Bravo',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });
}
