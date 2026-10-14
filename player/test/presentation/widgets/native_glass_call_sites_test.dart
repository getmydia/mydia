import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/native_glass_support.dart';
import 'package:player/presentation/widgets/cast_bar/cast_pill.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/native_glass.dart';
import 'package:player/presentation/widgets/nav/bottom_nav.dart';
import 'package:player/presentation/widgets/nav/dock_glass.dart';

void _mockPlatformViews(WidgetTester tester) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      SystemChannels.platform_views, (call) async => null);
  addTearDown(() =>
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, null));
}

Widget _host(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );

Widget _dock() => BottomNav(
      location: '/',
      onNavigate: (_) {},
      entries: const [],
    );

final _ios = TargetPlatformVariant.only(TargetPlatform.iOS);

void main() {
  tearDown(() => NativeGlassSupport.debugOverride = null);

  group('BottomNav', () {
    testWidgets('native: glass under the row at radius 22, no blur',
        (tester) async {
      NativeGlassSupport.debugOverride = true;
      _mockPlatformViews(tester);
      await tester.pumpWidget(_host(_dock()));
      await tester.pump();

      final glass = tester.widget<NativeGlass>(find.byType(NativeGlass));
      expect(glass.cornerRadius, 22);
      expect(find.byType(UiKitView), findsOneWidget);
      expect(find.byType(GlassSurface), findsNothing);
      expect(
        find.descendant(
            of: find.byType(NativeGlass), matching: find.byType(Row)),
        findsOneWidget,
      );
    }, variant: _ios);

    testWidgets('fallback: the DockGlass GlassSurface it always had',
        (tester) async {
      NativeGlassSupport.debugOverride = false;
      await tester.pumpWidget(_host(_dock()));

      final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
      expect(surface.blurSigma, DockGlass.blurSigma);
      expect(surface.fillColor, DockGlass.fill);
      expect(surface.borderRadius, BorderRadius.circular(22));
      expect(find.byType(UiKitView), findsNothing);
    }, variant: _ios);
  });

  group('CastPill', () {
    testWidgets('native: radius 18, same tint as the dock', (tester) async {
      NativeGlassSupport.debugOverride = true;
      _mockPlatformViews(tester);
      await tester.pumpWidget(
          _host(const CastPill(child: SizedBox(width: 200, height: 40))));
      await tester.pump();

      final glass = tester.widget<NativeGlass>(find.byType(NativeGlass));
      expect(glass.cornerRadius, 18);
      expect(glass.tint, isNull, reason: 'dock and pill share defaultTint');
      expect(find.byType(GlassSurface), findsNothing);
      // IconButton ink still needs the transparent Material.
      expect(
        find.descendant(
          of: find.byType(NativeGlass),
          matching: find.byWidgetPredicate(
              (w) => w is Material && w.type == MaterialType.transparency),
        ),
        findsOneWidget,
      );
    }, variant: _ios);

    testWidgets('fallback: unchanged GlassSurface', (tester) async {
      NativeGlassSupport.debugOverride = false;
      await tester.pumpWidget(
          _host(const CastPill(child: SizedBox(width: 200, height: 40))));

      final surface = tester.widget<GlassSurface>(find.byType(GlassSurface));
      expect(surface.borderRadius, CastPill.radius);
      expect(surface.fillColor, DockGlass.fill);
    }, variant: _ios);
  });
}
