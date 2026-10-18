import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/glass/glass_interaction.dart';
import 'package:player/presentation/widgets/glass/glass_pointer.dart';

GlassPointer? _pointer;

Widget _host({
  bool reduceMotion = false,
  bool enabled = true,
  VoidCallback? onTap,
}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Center(
          child: GlassInteraction(
            enabled: enabled,
            child: Builder(builder: (context) {
              _pointer = GlassPointer.maybeOf(context);
              return GestureDetector(
                onTap: onTap,
                behavior: HitTestBehavior.opaque,
                child: const SizedBox(width: 100, height: 40),
              );
            }),
          ),
        ),
      ),
    );

double _scale(WidgetTester tester) =>
    tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

void main() {
  testWidgets('press swells, moves the light, and release settles',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(onTap: () => taps++));
    expect(_scale(tester), 1.0);

    final gesture = await tester.startGesture(
        tester.getTopLeft(find.byType(GestureDetector)) + const Offset(75, 10));
    await tester.pump();
    expect(_scale(tester), DepthTokens.liquidPressScale);
    expect(_pointer?.pressed, isTrue);
    expect(_pointer?.light?.dx, closeTo(0.75, 0.01));
    expect(_pointer?.light?.dy, closeTo(0.25, 0.01));

    await gesture.up();
    await tester.pumpAndSettle();
    expect(_scale(tester), 1.0);
    expect(_pointer?.pressed, isFalse);
    expect(_pointer?.light, isNull);
    expect(taps, 1, reason: 'the child still receives the tap');
  });

  testWidgets('a pointer cancel clears pressed', (tester) async {
    await tester.pumpWidget(_host());
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(GestureDetector)));
    await tester.pump();
    expect(_pointer?.pressed, isTrue);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(_pointer?.pressed, isFalse);
    expect(_pointer?.light, isNull);
  });

  testWidgets('disabling mid-press does not leave the glass stuck pressed',
      (tester) async {
    await tester.pumpWidget(_host());
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(GestureDetector)));
    await tester.pump();
    expect(_pointer?.pressed, isTrue);

    await tester.pumpWidget(_host(enabled: false));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();
    expect(_pointer?.pressed, isFalse);
    expect(_pointer?.hovered, isFalse);
    expect(_pointer?.light, isNull);
    expect(_scale(tester), 1.0);
    await gesture.up();
  });

  testWidgets('hover brightens the rim', (tester) async {
    await tester.pumpWidget(_host());
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(GestureDetector)));
    await tester.pump();
    expect(_pointer?.hovered, isTrue);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    expect(_pointer?.hovered, isFalse);
  });

  testWidgets('Reduce Motion keeps the press to a brightness change',
      (tester) async {
    await tester.pumpWidget(_host(reduceMotion: true));
    final gesture = await tester
        .startGesture(tester.getCenter(find.byType(GestureDetector)));
    await tester.pump();
    expect(_scale(tester), 1.0);
    expect(_pointer?.pressed, isTrue);
    expect(_pointer?.light, isNull);
    await gesture.up();
  });
}
