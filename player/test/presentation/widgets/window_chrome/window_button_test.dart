import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/window/decoration_layout.dart';
import 'package:player/presentation/widgets/window_chrome/window_button.dart';

void main() {
  group('WindowButtonWidget', () {
    testWidgets('renders 46x40 rectangle with BorderRadius.zero on Windows',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowButtonWidget(
                button: WindowButton.close,
                onPressed: () {},
              ),
            ),
          ),
        );

        final container = tester.widget<AnimatedContainer>(
          find.byType(AnimatedContainer),
        );
        expect(container.constraints?.maxWidth, equals(46.0));
        expect(container.constraints?.maxHeight, equals(40.0));
        expect(tester.getSize(find.byType(WindowButtonWidget)),
            equals(const Size(46.0, 40.0)));

        final decoration = container.decoration as BoxDecoration;
        expect(decoration.borderRadius, equals(BorderRadius.zero));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('renders 28x28 square with rounded corners on Linux',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowButtonWidget(
                button: WindowButton.close,
                onPressed: () {},
              ),
            ),
          ),
        );

        final container = tester.widget<AnimatedContainer>(
          find.byType(AnimatedContainer),
        );
        expect(container.constraints?.maxWidth, equals(28.0));
        expect(container.constraints?.maxHeight, equals(28.0));
        expect(tester.getSize(find.byType(WindowButtonWidget)),
            equals(const Size(28.0, 28.0)));

        final decoration = container.decoration as BoxDecoration;
        expect(decoration.borderRadius, equals(BorderRadius.circular(6)));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('swaps maximize and restore glyphs', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowButtonWidget(
                button: WindowButton.maximize,
                isMaximized: false,
                onPressed: () {},
              ),
            ),
          ),
        );

        expect(find.byIcon(Icons.crop_square), findsOneWidget);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowButtonWidget(
                button: WindowButton.maximize,
                isMaximized: true,
                onPressed: () {},
              ),
            ),
          ),
        );

        expect(find.byIcon(Icons.filter_none), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('icon size is 13 for maximize on Windows and 15 for others',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowButtonWidget(
                button: WindowButton.maximize,
                onPressed: () {},
              ),
            ),
          ),
        );
        final maxIcon = tester.widget<Icon>(find.byType(Icon));
        expect(maxIcon.size, equals(13.0));

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowButtonWidget(
                button: WindowButton.close,
                onPressed: () {},
              ),
            ),
          ),
        );
        final closeIcon = tester.widget<Icon>(find.byType(Icon));
        expect(closeIcon.size, equals(15.0));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Windows Close button turns #E81123 on hover with white icon',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowButtonWidget(
                button: WindowButton.close,
                onPressed: () {},
              ),
            ),
          ),
        );

        final gesture =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        await tester.pump();

        await gesture.moveTo(tester.getCenter(find.byType(WindowButtonWidget)));
        await tester.pumpAndSettle();

        final container = tester.widget<AnimatedContainer>(
          find.byType(AnimatedContainer),
        );
        final decoration = container.decoration as BoxDecoration;
        expect(decoration.color, equals(const Color(0xFFE81123)));

        final icon = tester.widget<Icon>(find.byType(Icon));
        expect(icon.color, equals(Colors.white));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Windows Minimize button turns 0x1AFFFFFF on hover',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowButtonWidget(
                button: WindowButton.minimize,
                onPressed: () {},
              ),
            ),
          ),
        );

        final gesture =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        await tester.pump();

        await gesture.moveTo(tester.getCenter(find.byType(WindowButtonWidget)));
        await tester.pumpAndSettle();

        final container = tester.widget<AnimatedContainer>(
          find.byType(AnimatedContainer),
        );
        final decoration = container.decoration as BoxDecoration;
        expect(decoration.color, equals(const Color(0x1AFFFFFF)));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
        'Linux Close button turns AppColors.error on hover with textPrimary icon',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: WindowButtonWidget(
                button: WindowButton.close,
                onPressed: () {},
              ),
            ),
          ),
        );

        final gesture =
            await tester.createGesture(kind: PointerDeviceKind.mouse);
        await gesture.addPointer(location: Offset.zero);
        await tester.pump();

        await gesture.moveTo(tester.getCenter(find.byType(WindowButtonWidget)));
        await tester.pumpAndSettle();

        final container = tester.widget<AnimatedContainer>(
          find.byType(AnimatedContainer),
        );
        final decoration = container.decoration as BoxDecoration;
        expect(decoration.color, equals(AppColors.error));

        final icon = tester.widget<Icon>(find.byType(Icon));
        expect(icon.color, equals(AppColors.textPrimary));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('fires onPressed callback on tap', (tester) async {
      var pressed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WindowButtonWidget(
              button: WindowButton.close,
              onPressed: () => pressed = true,
            ),
          ),
        ),
      );

      await tester.tap(find.byType(WindowButtonWidget));
      expect(pressed, isTrue);
    });
  });
}
