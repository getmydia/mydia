import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/glass_accessibility.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_profile.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/dry_liquid_glass.dart';
import 'package:player/presentation/widgets/glass/liquid_glass_filter.dart';
import 'package:player/presentation/widgets/glass/osd_glass.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/osd_dialog.dart';
import 'package:player/presentation/widgets/osd_sheet.dart';

const _child = SizedBox(width: 80, height: 40);

Widget _host(
  Widget surface, {
  bool liquid = true,
  bool surfaceOutput = false,
  GlassAccessibility access = GlassAccessibility.none,
}) => MaterialApp(
  theme: AppTheme.build(Palettes.projectionBooth, liquid: liquid),
  home: GlassAccessibilityScope(
    value: access,
    child: OsdGlassScope(
      surfaceOutput: surfaceOutput,
      child: Scaffold(body: Center(child: surface)),
    ),
  ),
);

Future<void> _on(
  WidgetTester tester,
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  LiquidGlassSupport.debugOverride = true;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
    LiquidGlassSupport.debugOverride = null;
  }
}

List<BoxShadow> _shadows(WidgetTester tester) {
  final boxes = tester.widgetList<DecoratedBox>(
    find.descendant(
      of: find.byType(GlassSurface),
      matching: find.byType(DecoratedBox),
    ),
  );
  for (final b in boxes) {
    final d = b.decoration;
    if (d is BoxDecoration && d.boxShadow != null) return d.boxShadow!;
  }
  return const [];
}

void main() {
  group('sampled', () {
    testWidgets('osdPill takes the lens and the control tokens', (
      tester,
    ) async {
      await _on(tester, TargetPlatform.iOS, () async {
        await tester.pumpWidget(_host(GlassSurface.osdPill(child: _child)));
        final f = tester.widget<LiquidGlassFilter>(
          find.byType(LiquidGlassFilter),
        );
        expect(f.profile, LiquidGlassProfile.lens);
        expect(
          f.tint,
          DepthTokens.osdTint.withValues(
            alpha: DepthTokens.liquidControlTintOpacity,
          ),
        );
        expect(f.adaptiveTintMax, DepthTokens.liquidControlAdaptiveMax);
        expect(find.byType(DryLiquidGlass), findsNothing);
        expect(_shadows(tester), DepthTokens.osdShadowPill);
      });
    });

    testWidgets('osd takes the panel and the modal tokens', (tester) async {
      await _on(tester, TargetPlatform.iOS, () async {
        await tester.pumpWidget(_host(GlassSurface.osd(child: _child)));
        final f = tester.widget<LiquidGlassFilter>(
          find.byType(LiquidGlassFilter),
        );
        expect(f.profile, LiquidGlassProfile.panel);
        expect(
          f.tint,
          DepthTokens.osdTint.withValues(
            alpha: DepthTokens.liquidModalTintOpacity,
          ),
        );
        expect(f.adaptiveTintMax, DepthTokens.liquidModalAdaptiveMax);
        expect(_shadows(tester), DepthTokens.osdShadowPanel);
      });
    });

    testWidgets('a sheet keeps no shadow', (tester) async {
      await _on(tester, TargetPlatform.iOS, () async {
        await tester.pumpWidget(
          _host(GlassSurface.osd(elevation: OsdElevation.none, child: _child)),
        );
        expect(find.byType(LiquidGlassFilter), findsOneWidget);
        expect(_shadows(tester), isEmpty);
      });
    });
  });

  group('dry', () {
    testWidgets('osdPill and osd paint DryLiquidGlass, no filter', (
      tester,
    ) async {
      await _on(tester, TargetPlatform.macOS, () async {
        await tester.pumpWidget(
          _host(GlassSurface.osdPill(child: _child), surfaceOutput: true),
        );
        var d = tester.widget<DryLiquidGlass>(find.byType(DryLiquidGlass));
        expect(d.profile, LiquidGlassProfile.lens);
        expect(
          d.tint,
          DepthTokens.osdTint.withValues(alpha: DepthTokens.osdDryTintOpacity),
        );
        expect(find.byType(LiquidGlassFilter), findsNothing);
        expect(_shadows(tester), DepthTokens.osdShadowPill);

        await tester.pumpWidget(
          _host(GlassSurface.osd(child: _child), surfaceOutput: true),
        );
        d = tester.widget<DryLiquidGlass>(find.byType(DryLiquidGlass));
        expect(d.profile, LiquidGlassProfile.panel);
        expect(
          d.tint,
          DepthTokens.osdTint.withValues(
            alpha: DepthTokens.osdDryPanelTintOpacity,
          ),
        );
        expect(find.byType(LiquidGlassFilter), findsNothing);
        expect(_shadows(tester), DepthTokens.osdShadowPanel);
      });
    });

    testWidgets('Increase Contrast reaches the dry glass', (tester) async {
      await _on(tester, TargetPlatform.macOS, () async {
        await tester.pumpWidget(
          _host(
            GlassSurface.osdPill(child: _child),
            surfaceOutput: true,
            access: const GlassAccessibility(increaseContrast: true),
          ),
        );
        expect(
          tester
              .widget<DryLiquidGlass>(find.byType(DryLiquidGlass))
              .increaseContrast,
          isTrue,
        );
      });
    });
  });

  group('off', () {
    void expectToday(WidgetTester tester) {
      expect(find.byType(LiquidGlassFilter), findsNothing);
      expect(find.byType(DryLiquidGlass), findsNothing);
      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(GlassSurface),
              matching: find.byType(DecoratedBox),
            )
            .last,
      );
      expect(
        (box.decoration as BoxDecoration).color,
        DepthTokens.osdTint.withValues(alpha: DepthTokens.osdFillOpacity),
      );
    }

    testWidgets('non-liquid theme', (tester) async {
      await _on(tester, TargetPlatform.iOS, () async {
        await tester.pumpWidget(
          _host(GlassSurface.osdPill(child: _child), liquid: false),
        );
        expectToday(tester);
      });
    });

    testWidgets('android', (tester) async {
      await _on(tester, TargetPlatform.android, () async {
        await tester.pumpWidget(_host(GlassSurface.osd(child: _child)));
        expectToday(tester);
        expect(find.byType(BackdropFilter), findsOneWidget);
      });
    });

    testWidgets('reduce transparency', (tester) async {
      await _on(tester, TargetPlatform.iOS, () async {
        await tester.pumpWidget(
          _host(
            GlassSurface.osdPill(child: _child),
            access: const GlassAccessibility(reduceTransparency: true),
          ),
        );
        expectToday(tester);
        expect(find.byType(BackdropFilter), findsNothing);
        expect(_shadows(tester), DepthTokens.osdShadowPill);
      });
    });
  });

  testWidgets('flipping the theme between pumps switches trees', (
    tester,
  ) async {
    await _on(tester, TargetPlatform.iOS, () async {
      await tester.pumpWidget(_host(GlassSurface.osdPill(child: _child)));
      expect(find.byType(LiquidGlassFilter), findsOneWidget);
      await tester.pumpWidget(
        _host(GlassSurface.osdPill(child: _child), liquid: false),
      );
      // MaterialApp animates the theme change.
      await tester.pumpAndSettle();
      expect(find.byType(LiquidGlassFilter), findsNothing);
      await tester.pumpWidget(_host(GlassSurface.osdPill(child: _child)));
      await tester.pumpAndSettle();
      expect(find.byType(LiquidGlassFilter), findsOneWidget);
    });
  });

  group('routes under OsdGlassHost', () {
    Widget app(void Function(BuildContext) onTap) => ProviderScope(
      overrides: [videoSurfaceOutputProvider.overrideWith(_SurfaceOn.new)],
      child: MaterialApp(
        theme: AppTheme.build(Palettes.projectionBooth, liquid: true),
        builder: (context, child) => OsdGlassHost(child: child!),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => onTap(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

    testWidgets('a bottom sheet is dry glass', (tester) async {
      await _on(tester, TargetPlatform.macOS, () async {
        await tester.pumpWidget(
          app(
            (c) => showOsdBottomSheet<void>(
              context: c,
              builder: (_) => const SizedBox(height: 60, child: Text('sheet')),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byType(DryLiquidGlass), findsOneWidget);
        expect(find.byType(LiquidGlassFilter), findsNothing);
      });
    });

    testWidgets('a dialog is dry glass', (tester) async {
      await _on(tester, TargetPlatform.macOS, () async {
        await tester.pumpWidget(
          app(
            (c) => showDialog<void>(
              context: c,
              builder: (_) => const OsdDialog(
                title: Text('title'),
                content: Text('content'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byType(DryLiquidGlass), findsOneWidget);
        expect(find.byType(LiquidGlassFilter), findsNothing);
      });
    });
  });
}

class _SurfaceOn extends VideoSurfaceOutputNotifier {
  @override
  bool build() => true;
}
