import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/glass_dialog.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

ThemeData _theme({required bool liquid}) =>
    AppTheme.build(Palettes.projectionBooth, liquid: liquid);

Widget _host({required bool liquid}) => MaterialApp(
  theme: _theme(liquid: liquid),
  home: Scaffold(
    body: GlassDialog(
      icon: const Icon(Icons.warning_rounded),
      title: const Text('Remove account?'),
      content: const Text('This signs you out.'),
      actions: [
        TextButton(onPressed: () {}, child: const Text('Cancel')),
        FilledButton(onPressed: () {}, child: const Text('Remove')),
      ],
    ),
  ),
);

void main() {
  _focusTests();
  _frostedLayoutTests();
  _fixRoundTests();
  testWidgets('Liquid Glass: laid out on modal glass', (tester) async {
    await tester.pumpWidget(_host(liquid: true));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(GlassSurface), findsOneWidget);
    for (final text in [
      'Remove account?',
      'This signs you out.',
      'Cancel',
      'Remove',
    ]) {
      expect(find.text(text), findsOneWidget);
    }
    expect(find.byIcon(Icons.warning_rounded), findsOneWidget);
  });

  testWidgets('Liquid Glass: tall content scrolls instead of overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(liquid: true),
        home: Scaffold(
          body: Center(
            child: GlassDialog(
              title: const Text('Logs'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [for (var i = 0; i < 60; i++) Text('Row $i')],
              ),
              actions: [TextButton(onPressed: () {}, child: const Text('OK'))],
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });
}

/// Opens a [GlassDialog] through a real route so the route's focus scope is
/// the one the dialog's default-focus fallback inspects.
Future<void> _openDialog(
  WidgetTester tester, {
  required bool liquid,
  bool destructive = false,
  Widget? content,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(liquid: liquid),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => GlassDialog(
              destructive: destructive,
              title: const Text('Confirm'),
              content: content,
              actions: [
                TextButton(
                  key: const Key('first'),
                  onPressed: () {},
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  key: const Key('last'),
                  onPressed: () {},
                  child: const Text('Okay'),
                ),
              ],
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

bool _hasFocus(WidgetTester tester, Key key) => Focus.of(
  tester.element(
    find.descendant(of: find.byKey(key), matching: find.byType(Text)),
  ),
).hasPrimaryFocus;

void _focusTests() {
  for (final liquid in [true, false]) {
    final mode = liquid ? 'Liquid Glass' : 'Frosted';
    group('$mode default focus', () {
      testWidgets('lands on the last (primary) action', (tester) async {
        await _openDialog(tester, liquid: liquid);
        expect(_hasFocus(tester, const Key('last')), isTrue);
        expect(_hasFocus(tester, const Key('first')), isFalse);
      });

      testWidgets('destructive lands on the first action', (tester) async {
        await _openDialog(tester, liquid: liquid, destructive: true);
        expect(_hasFocus(tester, const Key('first')), isTrue);
        expect(_hasFocus(tester, const Key('last')), isFalse);
      });

      testWidgets('content that autofocuses keeps its focus', (tester) async {
        await _openDialog(
          tester,
          liquid: liquid,
          content: const TextField(key: Key('field'), autofocus: true),
        );
        final field = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        expect(field.widget.focusNode.hasPrimaryFocus, isTrue);
        expect(_hasFocus(tester, const Key('last')), isFalse);
      });

      testWidgets('UP from an action reaches the content', (tester) async {
        await _openDialog(
          tester,
          liquid: liquid,
          content: TextButton(
            key: const Key('content'),
            onPressed: () {},
            child: const Text('Add a note'),
          ),
        );
        expect(_hasFocus(tester, const Key('last')), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(_hasFocus(tester, const Key('content')), isTrue);
      });
    });
  }
}

const _cancelKey = Key('first');
const _okKey = Key('last');

/// The dialog's own surface: the first [Material] under [Dialog].
Finder get _card => find
    .descendant(of: find.byType(Dialog), matching: find.byType(Material))
    .first;

/// The fill of a button's own [Material].
Color? _fillOf(WidgetTester tester, Key key) => tester
    .widget<Material>(
      find
          .descendant(of: find.byKey(key), matching: find.byType(Material))
          .first,
    )
    .color;

void _frostedLayoutTests() {
  group('Frosted layout', () {
    testWidgets('centered card over the scrim', (tester) async {
      await _openDialog(
        tester,
        liquid: false,
        content: const Text('This signs you out.'),
      );
      final barriers = tester.widgetList<ModalBarrier>(
        find.byType(ModalBarrier),
      );
      expect(barriers.map((b) => b.color), contains(const Color(0x9E060607)));

      final material = tester.widget<Material>(_card);
      final p = Palettes.projectionBooth;
      expect(material.color, p.surfaceHigh);
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(20));
      expect(shape.side.color, const Color(0x14FFFFFF));

      final size = tester.getSize(_card);
      expect(size.width, lessThanOrEqualTo(GlassDialog.frostedMaxWidth));
      final center = tester.getCenter(_card);
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(center.dx, closeTo(screen.width / 2, 0.5));
      expect(center.dy, closeTo(screen.height / 2, 0.5));
    });

    testWidgets('actions stacked, primary on top', (tester) async {
      await _openDialog(tester, liquid: false);
      final ok = tester.getRect(find.byKey(_okKey));
      final cancel = tester.getRect(find.byKey(_cancelKey));
      expect(ok.top, lessThan(cancel.top));
      expect(ok.height, AppTheme.primaryButtonHeight);
      expect(cancel.height, AppTheme.primaryButtonHeight);
      final card = tester.getRect(_card);
      for (final action in [ok, cancel]) {
        expect(action.left, card.left + 10);
        expect(action.right, card.right - 10);
      }
      // The primary takes the filled style whatever widget the caller used.
      expect(_fillOf(tester, _okKey), Colors.white);
    });

    testWidgets('default focus is the primary', (tester) async {
      await _openDialog(tester, liquid: false);
      expect(_hasFocus(tester, _okKey), isTrue);
    });

    testWidgets('destructive keeps focus on cancel', (tester) async {
      await _openDialog(tester, liquid: false, destructive: true);
      expect(
        tester.getTopLeft(find.byKey(_okKey)).dy,
        lessThan(tester.getTopLeft(find.byKey(_cancelKey)).dy),
      );
      expect(_fillOf(tester, _okKey), AppColors.error.withValues(alpha: 0.16));
      expect(_hasFocus(tester, _cancelKey), isTrue);
      expect(_hasFocus(tester, _okKey), isFalse);
    });

    testWidgets('D-pad order follows the visual stack', (tester) async {
      await _openDialog(
        tester,
        liquid: false,
        content: TextButton(
          key: const Key('content'),
          onPressed: () {},
          child: const Text('Add a note'),
        ),
      );
      expect(_hasFocus(tester, _okKey), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(_hasFocus(tester, _cancelKey), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(_hasFocus(tester, _okKey), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(_hasFocus(tester, const Key('content')), isTrue);
    });

    testWidgets('no overflow at text scale 1.3', (tester) async {
      await _openDialog(
        tester,
        liquid: false,
        textScale: 1.3,
        content: const Text(
          'Downloads on this device stay until you remove them yourself.',
        ),
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getTopLeft(find.byKey(_okKey)).dy,
        lessThan(tester.getTopLeft(find.byKey(_cancelKey)).dy),
      );
    });

    testWidgets('wide dialog with two short actions lays them in a row', (
      tester,
    ) async {
      await _openDialog(
        tester,
        liquid: false,
        content: const SizedBox(width: 480, height: 20),
      );
      final card = tester.getRect(_card);
      expect(card.width, greaterThan(420));
      expect(card.width, lessThanOrEqualTo(GlassDialog.frostedWideMaxWidth));
      final ok = tester.getRect(find.byKey(_okKey));
      final cancel = tester.getRect(find.byKey(_cancelKey));
      expect(ok.top, cancel.top);
      // Reading order in a row: cancel, then the primary at the end.
      expect(cancel.right, lessThan(ok.left));
      expect(ok.right, card.right - 10);
    });

    testWidgets('a LayoutBuilder in fixed-width content lays out', (
      tester,
    ) async {
      // Sizing the card measures widths only; asking the content for
      // intrinsic heights would trip the LayoutBuilder's assertion.
      await _openDialog(
        tester,
        liquid: false,
        content: SizedBox(
          width: 460,
          child: LayoutBuilder(
            builder: (_, constraints) =>
                SizedBox(height: 40, width: constraints.maxWidth),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(_card).width, 460 + 2 * (10 + 14));
    });

    testWidgets('tall content scrolls and the actions stay', (tester) async {
      tester.view.physicalSize = const Size(400, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _openDialog(
        tester,
        liquid: false,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (var i = 0; i < 60; i++) Text('Row $i')],
        ),
      );
      expect(tester.takeException(), isNull);
      final card = tester.getRect(_card);
      expect(tester.getRect(find.byKey(_cancelKey)).bottom, card.bottom - 10);
    });

    testWidgets('no AlertDialog and no splash in Frosted', (tester) async {
      await _openDialog(tester, liquid: false);
      expect(find.byType(AlertDialog), findsNothing);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(_okKey)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final features =
          (Material.of(
                tester.element(find.text('Okay')),
              ) as dynamic).debugInkFeatures
              as List<InkFeature>?;
      expect(
        features?.where((f) => f is InkSplash || f is InkRipple) ?? const [],
        isEmpty,
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a single action is the primary and takes focus', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: _theme(liquid: false),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => GlassDialog(
                  title: const Text('Saved'),
                  actions: [
                    TextButton(
                      key: _okKey,
                      onPressed: () {},
                      child: const Text('OK'),
                    ),
                  ],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(_hasFocus(tester, _okKey), isTrue);
      expect(_fillOf(tester, _okKey), Colors.white);
    });
  });
}

/// Opens [builder]'s dialog through a real route.
Future<void> _openBuilt(
  WidgetTester tester, {
  required bool liquid,
  required WidgetBuilder builder,
  TextDirection textDirection = TextDirection.ltr,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(liquid: liquid),
      builder: (context, child) => Directionality(
        textDirection: textDirection,
        child: MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(context: context, builder: builder),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void _fixRoundTests() {
  for (final liquid in [true, false]) {
    final mode = liquid ? 'Liquid Glass' : 'Frosted';
    testWidgets('$mode: a disabled primary hands focus to Cancel, and '
        'enabling it later does not move focus', (tester) async {
      final enabled = ValueNotifier(false);
      addTearDown(enabled.dispose);
      await _openBuilt(
        tester,
        liquid: liquid,
        builder: (_) => ValueListenableBuilder<bool>(
          valueListenable: enabled,
          builder: (_, on, _) => GlassDialog(
            title: const Text('Pick a quality'),
            actions: [
              TextButton(
                key: _cancelKey,
                onPressed: () {},
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: _okKey,
                onPressed: on ? () {} : null,
                child: const Text('Okay'),
              ),
            ],
          ),
        ),
      );
      expect(_hasFocus(tester, _cancelKey), isTrue);
      enabled.value = true;
      await tester.pumpAndSettle();
      expect(_hasFocus(tester, _cancelKey), isTrue);
      expect(_hasFocus(tester, _okKey), isFalse);
    });
  }

  Widget styledDestructive(BuildContext context) => GlassDialog(
    destructive: true,
    backgroundColor: Colors.purple,
    title: const Text('Delete the download?'),
    actions: [
      TextButton(key: _cancelKey, onPressed: () {}, child: const Text('Keep')),
      FilledButton(
        key: _okKey,
        onPressed: () {},
        style: GlassDialog.liquidOnly(
          context,
          FilledButton.styleFrom(backgroundColor: AppColors.error),
        ),
        child: const Text('Delete'),
      ),
    ],
  );

  testWidgets('Frosted: liquidOnly drops a caller style; the tint shows and '
      'backgroundColor is ignored', (tester) async {
    await _openBuilt(tester, liquid: false, builder: styledDestructive);
    expect(_fillOf(tester, _okKey), AppColors.error.withValues(alpha: 0.16));
    expect(
      tester.widget<Material>(_card).color,
      Palettes.projectionBooth.surfaceHigh,
    );
  });

  testWidgets('Liquid Glass: liquidOnly keeps the caller style', (
    tester,
  ) async {
    await _openBuilt(tester, liquid: true, builder: styledDestructive);
    expect(_fillOf(tester, _okKey), AppColors.error);
  });

  Widget wideDialog(BuildContext context, {String title = 'Export'}) =>
      GlassDialog(
        title: Text(title),
        content: const SizedBox(width: 480, height: 20),
        actions: [
          TextButton(
            key: _cancelKey,
            onPressed: () {},
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: _okKey,
            onPressed: () {},
            child: const Text('Okay'),
          ),
        ],
      );

  testWidgets('Frosted: the action row mirrors under right-to-left', (
    tester,
  ) async {
    await _openBuilt(
      tester,
      liquid: false,
      textDirection: TextDirection.rtl,
      builder: wideDialog,
    );
    final card = tester.getRect(_card);
    final ok = tester.getRect(find.byKey(_okKey));
    final cancel = tester.getRect(find.byKey(_cancelKey));
    expect(ok.top, cancel.top);
    expect(ok.left, card.left + 10);
    expect(cancel.left, greaterThan(ok.right));
  });

  testWidgets('Frosted: a long title word at text scale 1.3 in row mode', (
    tester,
  ) async {
    await _openBuilt(
      tester,
      liquid: false,
      textScale: 1.3,
      builder: (context) =>
          wideDialog(context, title: 'Supercalifragilisticexpialidocious'),
    );
    expect(tester.takeException(), isNull);
    final card = tester.getRect(_card);
    expect(card.width, lessThanOrEqualTo(GlassDialog.frostedWideMaxWidth));
    expect(
      tester.getTopLeft(find.byKey(_okKey)).dy,
      tester.getTopLeft(find.byKey(_cancelKey)).dy,
    );
    expect(tester.getRect(find.byKey(_okKey)).right, card.right - 10);
  });
}
