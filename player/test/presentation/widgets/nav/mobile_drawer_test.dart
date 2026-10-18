import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/breakpoints.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/core/theme/liquid_glass/liquid_glass_support.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/nav/mobile_drawer.dart';

import '../../screens/sources/fake_capable_source.dart';
import '../../screens/sources/fake_media_source.dart';

const _padding = FakeViewPadding(left: 20, top: 47, bottom: 34);

Future<void> _openDrawer(WidgetTester tester,
    {ValueChanged<String>? onNavigate}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = _padding;
  addTearDown(tester.view.reset);
  final scaffoldKey = GlobalKey<ScaffoldState>();

  await tester.pumpWidget(ProviderScope(
    overrides: [
      sidebarLayoutStoreProvider
          .overrideWithValue(InMemorySidebarLayoutStore()),
      thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
      hasMydiaProvider.overrideWithValue(true),
      mediaSourceProvider(fakeSourceId).overrideWithValue(FakeCapableSource()),
    ],
    child: MaterialApp(
      home: Scaffold(
        key: scaffoldKey,
        drawer: MobileDrawer(location: '/', onNavigate: onNavigate ?? (_) {}),
        body: const SizedBox.expand(),
      ),
    ),
  ));
  scaffoldKey.currentState!.openDrawer();
  await tester.pumpAndSettle();
}

Finder get _glass => find.descendant(
      of: find.byType(MobileDrawer),
      matching: find.byType(GlassSurface),
    );

void main() {
  tearDown(() => LiquidGlassSupport.debugOverride = null);

  testWidgets('off Liquid Glass the drawer is edge to edge, rounded right',
      (tester) async {
    LiquidGlassSupport.debugOverride = false;
    await _openDrawer(tester);

    final glass = tester.widget<GlassSurface>(_glass);
    expect(
      glass.borderRadius,
      const BorderRadius.horizontal(
        right: Radius.circular(AppTheme.radiusRail),
      ),
    );
    final rect = tester.getRect(_glass);
    expect(rect.left, 0);
    expect(rect.top, 0);
    expect(rect.bottom, 800);
  });

  testWidgets('on Liquid Glass the drawer floats inset like the rail',
      (tester) async {
    LiquidGlassSupport.debugOverride = true;
    await _openDrawer(tester);

    final glass = tester.widget<GlassSurface>(_glass);
    expect(
      glass.borderRadius,
      const BorderRadius.all(Radius.circular(AppTheme.radiusRail)),
    );
    expect(
      glass.border,
      Border.all(color: DepthTokens.rimColor, width: DepthTokens.rimWidth),
    );
    expect(glass.shadows, DepthTokens.chrome);

    const inset = Breakpoints.railInset;
    final rect = tester.getRect(_glass);
    final drawer = tester.getRect(find.byType(Drawer));
    expect(rect.left, inset + _padding.left);
    expect(rect.top, inset + _padding.top);
    expect(rect.bottom, 800 - inset - _padding.bottom);
    expect(rect.right, drawer.right);
  });

  testWidgets('the floating drawer still navigates', (tester) async {
    LiquidGlassSupport.debugOverride = true;
    final routes = <String>[];
    await _openDrawer(tester, onNavigate: routes.add);

    await tester.tap(find.descendant(
      of: find.byType(MobileDrawer),
      matching: find.text('Settings'),
    ));
    await tester.pumpAndSettle();
    expect(routes, isNotEmpty);
  });
}
