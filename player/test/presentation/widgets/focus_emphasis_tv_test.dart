// On a television a focused button has to be obvious from the sofa. The
// buttons a viewer arrives on (Play, the version picker, the detail and home
// hero actions) grow and gain an accent ring with a glow, and every other
// Material button gains an accent border, whatever its fill: a white Play
// with a white or thin ring was nearly invisible.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/focus_emphasis.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:player/presentation/widgets/glass/glass_button.dart';
import 'package:player/presentation/widgets/primary_play_button.dart';

import '../../test_utils/tv_shell_harness.dart';

Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.darkTheme,
  home: Scaffold(body: Center(child: child)),
);

/// The emphasis around whatever holds focus now.
({double scale, bool ring}) _emphasis(WidgetTester tester, Finder of) {
  final finder = find.ancestor(of: of, matching: find.byType(FocusEmphasis));
  final scale = tester
      .widget<AnimatedScale>(
        find.descendant(
          of: finder.first,
          matching: find.byKey(FocusEmphasis.scaleKey),
        ),
      )
      .scale;
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: finder.first,
      matching: find.byKey(FocusEmphasis.ringKey),
    ),
  );
  return (
    scale: scale,
    ring: (paint.foregroundPainter! as FocusEmphasisPainter).visible,
  );
}

void main() {
  group('focused buttons on the television tier', () {
    testWidgets('an emphasized FocusHighlight grows and rings when focused', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      const box = Key('box');
      await tester.pumpWidget(
        _host(
          FocusHighlight(
            emphasis: true,
            focusNode: node,
            onActivate: () {},
            child: const SizedBox(key: box, width: 80, height: 40),
          ),
        ),
      );

      expect(_emphasis(tester, find.byKey(box)), (scale: 1.0, ring: false));

      node.requestFocus();
      await tester.pumpAndSettle();
      final focused = _emphasis(tester, find.byKey(box));
      expect(focused.scale, greaterThan(1.0));
      expect(focused.ring, isTrue);

      // Its own thin ring would sit inside the new one: it is not drawn.
      final own = tester.widget<DecoratedBox>(
        find.byKey(FocusHighlight.ringKey),
      );
      expect((own.decoration as BoxDecoration).border, isNull);
    });

    testWidgets('the ring is the palette accent', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        _host(
          FocusHighlight(
            emphasis: true,
            focusNode: node,
            onActivate: () {},
            child: const SizedBox(width: 80, height: 40),
          ),
        ),
      );
      node.requestFocus();
      await tester.pumpAndSettle();

      final paint = tester.widget<CustomPaint>(
        find.byKey(FocusEmphasis.ringKey),
      );
      final context = tester.element(find.byKey(FocusEmphasis.ringKey));
      expect(
        (paint.foregroundPainter! as FocusEmphasisPainter).color,
        context.palette.primary,
      );
    });

    testWidgets('focused, it paints only the accent ring by default', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        _host(
          FocusHighlight(
            emphasis: true,
            focusNode: node,
            onActivate: () {},
            child: const SizedBox(width: 80, height: 40),
          ),
        ),
      );
      final ring = find.byKey(FocusEmphasis.ringKey);
      final accent = tester.element(ring).palette.primary;
      expect(tester.renderObject(ring), isNot(paints..rrect()));

      node.requestFocus();
      await tester.pumpAndSettle();
      expect(
        tester.renderObject(ring),
        paints..rrect(
          color: accent,
          strokeWidth: FocusEmphasis.ringWidth,
          style: PaintingStyle.stroke,
        ),
      );
      // One stroke: no glow unless a glow colour is given.
      expect(
        tester.renderObject(ring),
        isNot(
          paints
            ..rrect()
            ..rrect(),
        ),
      );
    });

    testWidgets('given a glowColor, it paints that glow and then the ring', (
      tester,
    ) async {
      const glow = Color(0xFF3366CC);
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        _host(
          FocusHighlight(
            emphasis: true,
            emphasisGlow: glow,
            focusNode: node,
            onActivate: () {},
            child: const SizedBox(width: 80, height: 40),
          ),
        ),
      );
      final ring = find.byKey(FocusEmphasis.ringKey);
      final accent = tester.element(ring).palette.primary;

      node.requestFocus();
      await tester.pumpAndSettle();
      expect(
        tester.renderObject(ring),
        paints
          ..rrect(
            color: glow.withValues(alpha: 0.35),
            strokeWidth: FocusEmphasis.ringWidth * 2,
            style: PaintingStyle.stroke,
          )
          ..rrect(
            color: accent,
            strokeWidth: FocusEmphasis.ringWidth,
            style: PaintingStyle.stroke,
          ),
      );
    });

    testWidgets('the ring is 3 wide', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      await tester.pumpWidget(
        _host(
          FocusEmphasis(
            child: Focus(
              focusNode: node,
              child: const SizedBox(width: 80, height: 40),
            ),
          ),
        ),
      );
      node.requestFocus();
      await tester.pumpAndSettle();

      expect(FocusEmphasis.ringWidth, 3);
      expect(
        tester.renderObject(find.byKey(FocusEmphasis.ringKey)),
        paints..rrect(strokeWidth: 3, style: PaintingStyle.stroke),
      );
    });

    for (final (size, expected) in [
      (FocusSize.poster, 1.1),
      (FocusSize.tile, 1.05),
      (FocusSize.control, 1.025),
    ]) {
      testWidgets('a focused ${size.name} scales to $expected', (tester) async {
        final node = FocusNode();
        addTearDown(node.dispose);
        const box = Key('box');
        await tester.pumpWidget(
          _host(
            FocusEmphasis(
              size: size,
              child: Focus(
                focusNode: node,
                child: const SizedBox(key: box, width: 80, height: 40),
              ),
            ),
          ),
        );
        expect(_emphasis(tester, find.byKey(box)).scale, 1.0);

        node.requestFocus();
        await tester.pumpAndSettle();
        expect(_emphasis(tester, find.byKey(box)), (
          scale: expected,
          ring: true,
        ));
      });
    }

    testWidgets('the default size class is control', (tester) async {
      const box = Key('box');
      await tester.pumpWidget(
        _host(
          const FocusEmphasis(
            child: Focus(
              autofocus: true,
              child: SizedBox(key: box, width: 80, height: 40),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_emphasis(tester, find.byKey(box)).scale, FocusSize.control.scale);
    });

    testWidgets('FocusHighlight passes its size class through', (tester) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      const box = Key('box');
      await tester.pumpWidget(
        _host(
          FocusHighlight(
            emphasis: true,
            emphasisSize: FocusSize.poster,
            focusNode: node,
            onActivate: () {},
            child: const SizedBox(key: box, width: 80, height: 120),
          ),
        ),
      );
      node.requestFocus();
      await tester.pumpAndSettle();
      expect(_emphasis(tester, find.byKey(box)).scale, 1.1);
    });

    testWidgets('no scale when animations are disabled, ring still painted', (
      tester,
    ) async {
      final node = FocusNode();
      addTearDown(node.dispose);
      const box = Key('box');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.darkTheme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: FocusEmphasis(
                size: FocusSize.poster,
                child: Focus(
                  focusNode: node,
                  child: const SizedBox(key: box, width: 80, height: 120),
                ),
              ),
            ),
          ),
        ),
      );
      node.requestFocus();
      await tester.pumpAndSettle();
      expect(_emphasis(tester, find.byKey(box)), (scale: 1.0, ring: true));
    });

    testWidgets('a focused Play is emphasized', (tester) async {
      await tester.pumpWidget(
        _host(PrimaryPlayButton(onPressed: () {}, label: 'Play')),
      );
      FocusManager.instance.rootScope.traversalDescendants.first.requestFocus();
      await tester.pumpAndSettle();

      final play = _emphasis(tester, find.byKey(PrimaryPlayButton.pillKey));
      expect(play.scale, greaterThan(1.0));
      expect(play.ring, isTrue);
    });

    testWidgets('a focused GlassButton is emphasized', (tester) async {
      const key = Key('more');
      await tester.pumpWidget(
        _host(GlassButton(buttonKey: key, label: 'More', onPressed: () {})),
      );
      FocusManager.instance.rootScope.traversalDescendants.first.requestFocus();
      await tester.pumpAndSettle();

      final more = _emphasis(tester, find.byKey(key));
      expect(more.scale, greaterThan(1.0));
      expect(more.ring, isTrue);
    });

    testWidgets('a focused GlassButton on Liquid Glass is emphasized', (
      tester,
    ) async {
      const key = Key('more');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(Palettes.projectionBooth, liquid: true),
          home: Scaffold(
            body: Center(
              child: GlassButton(
                buttonKey: key,
                label: 'More',
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
      FocusManager.instance.rootScope.traversalDescendants.first.requestFocus();
      await tester.pumpAndSettle();

      final more = _emphasis(tester, find.byKey(key));
      expect(more.scale, greaterThan(1.0));
      expect(more.ring, isTrue);
    });

    testWidgets('every Material button gets an accent border when focused', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const SizedBox()));
      final context = tester.element(find.byType(SizedBox));
      final theme = Theme.of(context);
      final accent = context.palette.primary;
      for (final style in [
        theme.filledButtonTheme.style,
        theme.elevatedButtonTheme.style,
        theme.outlinedButtonTheme.style,
        theme.textButtonTheme.style,
      ]) {
        final side = style!.side!.resolve({WidgetState.focused});
        expect(side?.color, accent);
        expect(side!.width, greaterThanOrEqualTo(3));
        final rest = style.side!.resolve({});
        expect(
          rest == null || rest.width == 0 || rest == BorderSide.none,
          isTrue,
        );
      }
    });
  }, skip: tvSkipReason);
}
