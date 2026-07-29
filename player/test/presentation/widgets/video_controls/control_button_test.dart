import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/video_controls/control_button.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

Icon _iconOf(WidgetTester tester) =>
    tester.widget<Icon>(find.byType(Icon).first);

void main() {
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

    testWidgets('shows a hover backdrop on pointer enter', (tester) async {
      await tester.pumpWidget(
        _host(ControlButton(icon: Icons.play_arrow_rounded, onTap: () {})),
      );

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(ControlButton)));
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
  });
}
