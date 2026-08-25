import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:player/presentation/widgets/video_controls/control_button.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

Icon _iconOf(WidgetTester tester) =>
    tester.widget<Icon>(find.byType(Icon).first);

/// Scopes a finder to descendants of the `ControlButton` under test, since
/// `MaterialApp`/`Scaffold` also contain their own `Focus`/`DecoratedBox`
/// instances elsewhere in the tree.
Finder _withinButton(Finder matching) =>
    find.descendant(of: find.byType(ControlButton), matching: matching);

/// `FocusableActionDetector` wraps its `Focus` in a `Shortcuts` widget when
/// interactive, and `Shortcuts` installs a `Focus` of its own (with no
/// `focusNode` of its own) to capture key events for matching. That makes
/// `find.byType(Focus)` ambiguous within the button once activation is
/// wired up, so this picks out the one actually carrying a node rather than
/// asserting there is exactly one.
FocusNode _focusNodeOf(WidgetTester tester) => tester
    .widgetList<Focus>(_withinButton(find.byType(Focus)))
    .firstWhere((focus) => focus.focusNode != null)
    .focusNode!;

/// The focus ring now lives on `FocusHighlight`, which `ControlButton` wraps
/// around its glyph. Retargeted here from the button's own inner
/// `DecoratedBox` (which no longer paints a border) at the same key
/// `FocusHighlight` exposes for exactly this purpose.
BoxDecoration _decorationOf(WidgetTester tester) =>
    tester.widget<DecoratedBox>(find.byKey(FocusHighlight.ringKey)).decoration
        as BoxDecoration;

void main() {
  // FocusHighlight's ring is gated on FocusManager.highlightMode, which
  // flutter_test otherwise derives from the default target platform
  // (android), so `onShowFocusHighlight` never fires and the ring tests
  // below could never see a ring. Forcing the traditional strategy is the
  // documented way to test focus visuals, and matches what a real keyboard
  // or D-pad event does at runtime.
  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });

  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  group('ControlButton', () {
    testWidgets('carries no per-glyph shadow (the glass backs it instead)',
        (tester) async {
      await tester.pumpWidget(
        _host(const ControlButton(icon: Icons.play_arrow_rounded)),
      );

      final shadows = _iconOf(tester).shadows;
      expect(shadows == null || shadows.isEmpty, isTrue);
    });

    testWidgets('renders at rest opacity', (tester) async {
      await tester.pumpWidget(
        _host(const ControlButton(icon: Icons.play_arrow_rounded)),
      );

      expect(_iconOf(tester).color?.a, closeTo(0.92, 0.001));
    });

    testWidgets('dims when disabled and does not fire', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          ControlButton(
            icon: Icons.play_arrow_rounded,
            enabled: false,
            onTap: () => tapped = true,
          ),
        ),
      );

      expect(_iconOf(tester).color?.a, closeTo(0.30, 0.001));
      await tester.tap(find.byType(ControlButton));
      expect(tapped, isFalse);
    });

    testWidgets('fires when enabled', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          ControlButton(
            icon: Icons.play_arrow_rounded,
            onTap: () => tapped = true,
          ),
        ),
      );

      await tester.tap(find.byType(ControlButton));
      expect(tapped, isTrue);
    });

    testWidgets('default target meets the 44px touch minimum', (tester) async {
      await tester.pumpWidget(
        _host(const ControlButton(icon: Icons.play_arrow_rounded)),
      );

      final size = tester.getSize(find.byType(ControlButton));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    });

    testWidgets(
        'shows a hover backdrop on pointer enter, animating the glyph '
        'alongside it rather than snapping', (tester) async {
      await tester.pumpWidget(
        _host(ControlButton(icon: Icons.play_arrow_rounded, onTap: () {})),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(ControlButton)));
      // One frame to let the pointer-enter setState take effect and the
      // hover transition begin, then advance partway through it. An instant
      // jump (the pre-fix behaviour) would already read 1.0 here; a real
      // 150ms transition should still be mid-flight.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 75));
      final midAlpha = _iconOf(tester).color!.a;
      expect(midAlpha, greaterThan(0.92));
      expect(midAlpha, lessThan(1.0));

      await tester.pumpAndSettle();
      expect(_iconOf(tester).color?.a, closeTo(1.0, 0.001));
    });

    testWidgets(
        'stays at rest opacity on hover when it has no onTap (not interactive)',
        (tester) async {
      await tester.pumpWidget(
        _host(const ControlButton(icon: Icons.play_arrow_rounded)),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(ControlButton)));
      await tester.pumpAndSettle();

      expect(_iconOf(tester).color?.a, closeTo(0.92, 0.001));
    });

    testWidgets('reduced motion drops the press scale', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _host(
            ControlButton(icon: Icons.play_arrow_rounded, onTap: () {}),
          ),
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(ControlButton)),
      );
      addTearDown(() async {
        if (tester.binding.hasScheduledFrame) {
          await tester.pumpAndSettle();
        }
      });
      await tester.pump();

      expect(
        tester
            .widget<AnimatedScale>(_withinButton(find.byType(AnimatedScale)))
            .scale,
        1.0,
      );

      await gesture.up();
    });

    testWidgets('renders a 2px white@0.60 focus ring when focused',
        (tester) async {
      await tester.pumpWidget(
        _host(ControlButton(icon: Icons.play_arrow_rounded, onTap: () {})),
      );

      final focusNode = _focusNodeOf(tester);
      focusNode.requestFocus();
      await tester.pump();

      final decoration = _decorationOf(tester);
      final border = decoration.border as Border;

      expect(border.top.width, 2);
      expect(border.top.color.a, closeTo(0.60, 0.001));
    });

    testWidgets('does not render a focus ring when not focused',
        (tester) async {
      await tester.pumpWidget(
        _host(ControlButton(icon: Icons.play_arrow_rounded, onTap: () {})),
      );

      final decoration = _decorationOf(tester);

      expect(decoration.border, isNull);
    });

    testWidgets('activates onTap via Enter when focused', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          ControlButton(
            icon: Icons.play_arrow_rounded,
            onTap: () => tapped = true,
          ),
        ),
      );

      final focusNode = _focusNodeOf(tester);
      focusNode.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(tapped, isTrue);
    });

    testWidgets('activates onTap via Space when focused', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          ControlButton(
            icon: Icons.play_arrow_rounded,
            onTap: () => tapped = true,
          ),
        ),
      );

      final focusNode = _focusNodeOf(tester);
      focusNode.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(tapped, isTrue);
    });

    testWidgets(
        'a focused but non-interactive button ignores Enter/Space '
        '(disabled)', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          ControlButton(
            icon: Icons.play_arrow_rounded,
            enabled: false,
            onTap: () => tapped = true,
          ),
        ),
      );

      final focusNode = _focusNodeOf(tester);
      // A disabled button can't request focus, so this should be a no-op.
      focusNode.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(tapped, isFalse);
    });
  });
}
