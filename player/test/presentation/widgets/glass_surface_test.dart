import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/platform_features.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

BackdropFilter _backdropOf(WidgetTester tester) {
  return tester.widget<BackdropFilter>(find.byType(BackdropFilter));
}

/// Extracts the blur sigma from a [BackdropFilter]'s image filter by matching
/// against a freshly built blur filter (ImageFilter equality is value-based).
bool _hasBlurSigma(BackdropFilter f, double sigma) {
  return f.filter == ImageFilter.blur(sigmaX: sigma, sigmaY: sigma);
}

DecoratedBox _decoratedBoxOf(WidgetTester tester) {
  return tester.widget<DecoratedBox>(
    find.descendant(
      of: find.byType(BackdropFilter),
      matching: find.byType(DecoratedBox),
    ),
  );
}

void main() {
  group('GlassSurface.appBar', () {
    testWidgets('renders a BackdropFilter with sigma 10 and the fill opacity',
        (tester) async {
      await tester.pumpWidget(
        _host(
            GlassSurface.appBar(child: const SizedBox(width: 50, height: 50))),
      );

      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(_hasBlurSigma(_backdropOf(tester), 10), isTrue);

      final decoration = _decoratedBoxOf(tester).decoration as BoxDecoration;
      expect(
        decoration.color,
        AppColors.background.withValues(alpha: 0.8),
      );
    });

    testWidgets('honors an explicit opacity override (0.85)', (tester) async {
      await tester.pumpWidget(
        _host(GlassSurface.appBar(opacity: 0.85, child: const SizedBox())),
      );
      final decoration = _decoratedBoxOf(tester).decoration as BoxDecoration;
      expect(
        decoration.color,
        AppColors.background.withValues(alpha: 0.85),
      );
    });
  });

  group('GlassSurface.modal', () {
    testWidgets('renders border + radius 20 + sigma 8 fill at 0.6',
        (tester) async {
      await tester.pumpWidget(
        _host(GlassSurface.modal(child: const SizedBox())),
      );

      expect(_hasBlurSigma(_backdropOf(tester), 8), isTrue);

      final decoration = _decoratedBoxOf(tester).decoration as BoxDecoration;
      expect(decoration.color, AppColors.surface.withValues(alpha: 0.6));
      expect(decoration.border, isNotNull);
      expect(decoration.borderRadius, BorderRadius.circular(20));
    });
  });

  group('GlassSurface.hoverOverlay', () {
    testWidgets('renders sigma 2 with a dark gradient and radius 12',
        (tester) async {
      await tester.pumpWidget(
        _host(GlassSurface.hoverOverlay(child: const SizedBox())),
      );

      expect(_hasBlurSigma(_backdropOf(tester), 2), isTrue);

      final decoration = _decoratedBoxOf(tester).decoration as BoxDecoration;
      expect(decoration.gradient, isA<LinearGradient>());
      expect(decoration.borderRadius, BorderRadius.circular(12));
    });

    testWidgets('honors a custom borderRadius', (tester) async {
      await tester.pumpWidget(
        _host(
          GlassSurface.hoverOverlay(
            borderRadius: BorderRadius.circular(8),
            child: const SizedBox(),
          ),
        ),
      );
      final decoration = _decoratedBoxOf(tester).decoration as BoxDecoration;
      expect(decoration.borderRadius, BorderRadius.circular(8));
    });
  });

  group('GlassSurface.faux (R8)', () {
    testWidgets('renders no BackdropFilter while painting fill + rim',
        (tester) async {
      await tester.pumpWidget(
        _host(
          GlassSurface.faux(
            fillColor: AppColors.surface.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            child: const SizedBox(width: 50, height: 50),
          ),
        ),
      );

      // The whole point of faux-glass: zero live blur passes.
      expect(find.byType(BackdropFilter), findsNothing);

      final decorated = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(ClipRRect),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decoration = decorated.decoration as BoxDecoration;
      expect(decoration.color, AppColors.surface.withValues(alpha: 0.5));
      // Rim is applied by default.
      expect(decoration.border, isNotNull);
    });

    testWidgets('still wraps in a RepaintBoundary', (tester) async {
      await tester.pumpWidget(
        _host(GlassSurface.faux(child: const SizedBox())),
      );
      expect(
        find.ancestor(
          of: find.byType(ClipRRect),
          matching: find.byType(RepaintBoundary),
        ),
        findsWidgets,
      );
    });

    testWidgets('showRim: false drops the rim border', (tester) async {
      await tester.pumpWidget(
        _host(
          GlassSurface.faux(
            showRim: false,
            gradient: const LinearGradient(
              colors: [Colors.black, Colors.transparent],
            ),
            child: const SizedBox(),
          ),
        ),
      );
      final decorated = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(ClipRRect),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decoration = decorated.decoration as BoxDecoration;
      expect(decoration.border, isNull);
      expect(decoration.gradient, isA<LinearGradient>());
    });

    testWidgets(
        'a faux surface and a real-blur surface co-render; only the '
        'real one adds a blur pass', (tester) async {
      await tester.pumpWidget(
        _host(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GlassSurface.appBar(child: const Text('real')),
              GlassSurface.faux(child: const Text('faux')),
            ],
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.text('real'), findsOneWidget);
      expect(find.text('faux'), findsOneWidget);
    });
  });

  group('grouped rendering', () {
    testWidgets(
        'a BackdropGroup wrapping two grouped surfaces builds and '
        'both render', (tester) async {
      await tester.pumpWidget(
        _host(
          BackdropGroup(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlassSurface.appBar(
                  grouped: true,
                  child: const Text('one'),
                ),
                GlassSurface.modal(
                  grouped: true,
                  child: const Text('two'),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.byType(BackdropGroup), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNWidgets(2));
      expect(find.text('one'), findsOneWidget);
      expect(find.text('two'), findsOneWidget);
    });
  });

  group('child rendering', () {
    testWidgets('renders its child in every preset', (tester) async {
      for (final surface in [
        GlassSurface.appBar(child: const Text('appbar')),
        GlassSurface.modal(child: const Text('modal')),
        GlassSurface.hoverOverlay(child: const Text('hover')),
      ]) {
        await tester.pumpWidget(_host(surface));
        await tester.pump();
      }
      // Last pump is the hover overlay preset.
      expect(find.text('hover'), findsOneWidget);
    });

    testWidgets('wraps the blur region in a RepaintBoundary', (tester) async {
      await tester.pumpWidget(
        _host(GlassSurface.appBar(child: const SizedBox())),
      );
      expect(
        find.ancestor(
          of: find.byType(BackdropFilter),
          matching: find.byType(RepaintBoundary),
        ),
        findsWidgets,
      );
    });
  });

  group('GlassSurface.playerChrome', () {
    Widget host(Widget child) => MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                const Positioned.fill(child: ColoredBox(color: Colors.white)),
                Align(alignment: Alignment.bottomCenter, child: child),
              ],
            ),
          ),
        );

    BoxDecoration decorationOf(WidgetTester tester) => tester
        .widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(GlassSurface),
                matching: find.byType(DecoratedBox),
              )
              .first,
        )
        .decoration as BoxDecoration;

    testWidgets('full tier composes blur with a saturation matrix',
        (tester) async {
      await tester.pumpWidget(
        host(
          GlassSurface.playerChrome(
            tier: PlayerGlassTier.full,
            child: const SizedBox(width: 200, height: 60),
          ),
        ),
      );

      expect(find.byType(BackdropFilter), findsOneWidget);
      final filter =
          tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter;
      // A composed filter is not equal to a bare blur of the same sigma.
      expect(
        filter,
        isNot(ImageFilter.blur(
          sigmaX: DepthTokens.blurPlayerChrome,
          sigmaY: DepthTokens.blurPlayerChrome,
        )),
      );
    });

    testWidgets('reduced tier uses a bare blur, no colour matrix',
        (tester) async {
      await tester.pumpWidget(
        host(
          GlassSurface.playerChrome(
            tier: PlayerGlassTier.reduced,
            child: const SizedBox(width: 200, height: 60),
          ),
        ),
      );

      final filter =
          tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter;
      expect(
        filter,
        ImageFilter.blur(
          sigmaX: DepthTokens.blurPlayerChrome,
          sigmaY: DepthTokens.blurPlayerChrome,
        ),
      );
    });

    testWidgets('faux tier renders no BackdropFilter', (tester) async {
      await tester.pumpWidget(
        host(
          GlassSurface.playerChrome(
            tier: PlayerGlassTier.faux,
            child: const SizedBox(width: 200, height: 60),
          ),
        ),
      );

      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('fill is a vertical gradient, denser at the bottom',
        (tester) async {
      await tester.pumpWidget(
        host(
          GlassSurface.playerChrome(
            tier: PlayerGlassTier.full,
            child: const SizedBox(width: 200, height: 60),
          ),
        ),
      );

      final gradient = decorationOf(tester).gradient! as LinearGradient;
      expect(gradient.begin, Alignment.topCenter);
      expect(gradient.end, Alignment.bottomCenter);
      expect(gradient.colors.first.a, DepthTokens.playerChromeFillTopAlpha);
      expect(gradient.colors.last.a, DepthTokens.playerChromeFillBottomAlpha);
      expect(gradient.colors.last.a, greaterThan(gradient.colors.first.a));
    });

    testWidgets('rim is directional: top and bottom only, no side borders',
        (tester) async {
      await tester.pumpWidget(
        host(
          GlassSurface.playerChrome(
            tier: PlayerGlassTier.full,
            child: const SizedBox(width: 200, height: 60),
          ),
        ),
      );

      final border = decorationOf(tester).border! as Border;
      expect(border.top.color, DepthTokens.playerRimTop);
      expect(border.bottom.color, DepthTokens.playerRimBottom);
      expect(border.left.style, BorderStyle.none);
      expect(border.right.style, BorderStyle.none);
    });

    testWidgets('children remain hit-testable', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        host(
          GlassSurface.playerChrome(
            tier: PlayerGlassTier.full,
            child: ElevatedButton(
              onPressed: () => tapped = true,
              child: const Text('play'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('play'));
      expect(tapped, isTrue);
    });
  });
}
