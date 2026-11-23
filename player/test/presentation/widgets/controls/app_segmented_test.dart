import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/controls/app_segmented.dart';

final _palette = Palettes.projectionBooth;

const _sizes = [
  AppSegment(value: 's', label: 'S', semanticLabel: 'Small'),
  AppSegment(value: 'm', label: 'M', semanticLabel: 'Medium'),
  AppSegment(value: 'l', label: 'L', semanticLabel: 'Large'),
  AppSegment(value: 'xl', label: 'XL', semanticLabel: 'Extra large'),
];

/// Hosts the control above a plain button, so traversal has somewhere to go.
Widget _host(
  Widget control, {
  bool disableAnimations = false,
  double textScale = 1,
}) {
  // MaterialApp, not a bare Theme: it installs the default shortcuts that
  // map Tab and the arrows to focus traversal.
  return MaterialApp(
    theme: AppTheme.build(_palette, liquid: false),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        disableAnimations: disableAnimations,
        textScaler: TextScaler.linear(textScale),
      ),
      child: child!,
    ),
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
  const _Harness({required this.initial, required this.log});

  final String initial;
  final List<String> log;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late String _value = widget.initial;

  @override
  Widget build(BuildContext context) => AppSegmented<String>(
    segments: _sizes,
    selected: _value,
    semanticLabel: 'Subtitle size',
    onChanged: (v) {
      widget.log.add(v);
      setState(() => _value = v);
    },
  );
}

bool _insideControl(WidgetTester tester, FocusNode? node) {
  final context = node?.context;
  if (context == null) return false;
  return find
      .descendant(
        of: find.byType(AppSegmented<String>),
        matching: find.byElementPredicate((e) => e == context),
      )
      .evaluate()
      .isNotEmpty;
}

void main() {
  testWidgets('renders track and selected thumb', (tester) async {
    await tester.pumpWidget(
      _host(
        AppSegmented<String>(
          segments: _sizes,
          selected: 'l',
          onChanged: (_) {},
        ),
      ),
    );

    final track = tester.widget<Container>(find.byKey(AppSegmented.trackKey));
    final deco = track.decoration! as BoxDecoration;
    expect(deco.color, _palette.surfaceLow);
    expect(deco.borderRadius, BorderRadius.circular(11));
    final border = deco.border! as Border;
    expect(border.top.color, const Color(0x24FFFFFF));
    expect(border.top.strokeAlign, BorderSide.strokeAlignInside);

    final thumb = find.byKey(AppSegmented.thumbKey);
    final thumbDeco =
        tester.widget<DecoratedBox>(thumb).decoration as BoxDecoration;
    expect(thumbDeco.color, _palette.surfaceBright);

    // Padding 3: the thumb sits 3 inside the track on every side.
    final trackRect = tester.getRect(find.byKey(AppSegmented.trackKey));
    final firstThumb = tester.getRect(find.byKey(AppSegmented.thumbKey));
    expect(firstThumb.top - trackRect.top, 3);
    expect(trackRect.bottom - firstThumb.bottom, 3);
    expect(thumbDeco.borderRadius, BorderRadius.circular(8));
    expect(firstThumb.height, greaterThanOrEqualTo(30));

    // The thumb sits over the third segment.
    final thumbCentre = tester.getCenter(thumb).dx;
    final third = tester.getRect(find.text('L'));
    expect(thumbCentre, closeTo(third.center.dx, 2));

    for (var i = 0; i < _sizes.length; i++) {
      expect(
        tester.getSize(find.byKey(AppSegmented.segmentKey(i))).height,
        greaterThanOrEqualTo(44),
      );
    }
  });

  testWidgets('one focus stop; Left/Right change the selection', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(_host(_Harness(initial: 'l', log: log)));

    // Tab reaches the control once, then the button below: one stop.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final node = FocusManager.instance.primaryFocus;
    expect(_insideControl(tester, node), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      Focus.of(tester.element(find.text('Below'))).hasFocus,
      isTrue,
      reason: 'the second Tab leaves the control for the next widget',
    );
    // Back on the control.
    node?.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(log, ['xl']);

    // At the last segment: no wrap, and focus stays.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(log, ['xl']);
    expect(node?.hasPrimaryFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(log, ['xl', 'l']);

    // Down leaves by ordinary traversal.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(node?.hasFocus, isFalse);
    expect(Focus.of(tester.element(find.text('Below'))).hasFocus, isTrue);
  });

  testWidgets('at an end a held arrow stays, a fresh press moves on', (
    tester,
  ) async {
    final log = <String>[];
    await tester.pumpWidget(
      _host(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(onPressed: () {}, child: const Text('Left of it')),
            const SizedBox(width: 24),
            _Harness(initial: 'm', log: log),
          ],
        ),
      ),
    );
    final control = find.byType(AppSegmented<String>);
    // The button, then the control.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final node = FocusManager.instance.primaryFocus;
    expect(_insideControl(tester, node), isTrue);
    expect(control, findsOneWidget);

    // Held Left: steps to S, then the repeats at the end are swallowed.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pump();
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(log, ['s']);
    expect(node?.hasPrimaryFocus, isTrue);

    // A fresh press at the end is ordinary traversal.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(log, ['s']);
    expect(node?.hasFocus, isFalse);
    expect(Focus.of(tester.element(find.text('Left of it'))).hasFocus, isTrue);
  });

  testWidgets('tap selects', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(_host(_Harness(initial: 'm', log: log)));
    await tester.tap(find.byKey(AppSegmented.segmentKey(3)));
    await tester.pumpAndSettle();
    expect(log, ['xl']);

    // Tapping the selected segment reports nothing.
    await tester.tap(find.byKey(AppSegmented.segmentKey(3)));
    await tester.pumpAndSettle();
    expect(log, ['xl']);
  });

  testWidgets('Select key does nothing extra', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(_host(_Harness(initial: 'm', log: log)));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final node = FocusManager.instance.primaryFocus;

    for (final key in [
      LogicalKeyboardKey.select,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.space,
    ]) {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }
    expect(log, isEmpty);
    expect(node?.hasPrimaryFocus, isTrue);
  });

  testWidgets('semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        AppSegmented<String>(
          segments: _sizes,
          selected: 'm',
          semanticLabel: 'Subtitle size',
          onChanged: (_) {},
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byType(AppSegmented<String>)),
      isSemantics(label: 'Subtitle size'),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Medium')),
      isSemantics(isButton: true, isSelected: true),
    );
    for (final name in ['Small', 'Large', 'Extra large']) {
      expect(
        tester.getSemantics(find.bySemanticsLabel(name)),
        isSemantics(isButton: true, isSelected: false),
        reason: name,
      );
    }
    handle.dispose();
  });

  testWidgets('reduced motion: thumb jumps without animation', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(
      _host(_Harness(initial: 's', log: log), disableAnimations: true),
    );
    await tester.tap(find.byKey(AppSegmented.segmentKey(3)));
    await tester.pump();

    final thumb = tester.getCenter(find.byKey(AppSegmented.thumbKey)).dx;
    final last = tester.getRect(find.text('XL'));
    expect(thumb, closeTo(last.center.dx, 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('animates the thumb when motion is allowed', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(_host(_Harness(initial: 's', log: log)));
    await tester.tap(find.byKey(AppSegmented.segmentKey(3)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    final mid = tester.getCenter(find.byKey(AppSegmented.thumbKey)).dx;
    final last = tester.getRect(find.text('XL'));
    expect(mid, lessThan(last.center.dx - 2));
    await tester.pumpAndSettle();
  });

  testWidgets('right to left: thumb follows the segment', (tester) async {
    await tester.pumpWidget(
      _host(
        Directionality(
          textDirection: TextDirection.rtl,
          child: AppSegmented<String>(
            segments: _sizes,
            selected: 's',
            onChanged: (_) {},
          ),
        ),
      ),
    );
    final thumb = tester.getCenter(find.byKey(AppSegmented.thumbKey)).dx;
    expect(thumb, closeTo(tester.getCenter(find.text('S')).dx, 2));
    expect(
      tester.getCenter(find.text('S')).dx,
      greaterThan(tester.getCenter(find.text('XL')).dx),
    );
  });

  group('text scale 1.3 does not overflow', () {
    testWidgets('S M L XL', (tester) async {
      await tester.pumpWidget(
        _host(
          AppSegmented<String>(
            segments: _sizes,
            selected: 'm',
            onChanged: (_) {},
          ),
          textScale: 1.3,
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('two long labels in a narrow column', (tester) async {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 220,
            child: AppSegmented<int>(
              segments: const [
                AppSegment(value: 0, label: 'Somente não assistidos'),
                AppSegment(value: 1, label: 'Todos os favoritos marcados'),
              ],
              selected: 0,
              onChanged: (_) {},
            ),
          ),
          textScale: 1.3,
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getSize(find.byType(AppSegmented<int>)).width, 220);
    });
  });

  test('asserts two to four segments', () {
    expect(
      () => AppSegmented<int>(
        segments: const [AppSegment(value: 0, label: 'One')],
        selected: 0,
        onChanged: (_) {},
      ),
      throwsAssertionError,
    );
  });
}
