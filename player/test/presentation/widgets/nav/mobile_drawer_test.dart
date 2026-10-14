import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/nav/mobile_drawer.dart';

import '../../screens/sources/fake_capable_source.dart';
import '../../screens/sources/fake_media_source.dart';

void main() {
  testWidgets('the drawer is glass with the rail radius on its right side',
      (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scaffoldKey = GlobalKey<ScaffoldState>();

    await tester.pumpWidget(ProviderScope(
      overrides: [
        sidebarLayoutStoreProvider
            .overrideWithValue(InMemorySidebarLayoutStore()),
        thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
        hasMydiaProvider.overrideWithValue(true),
        mediaSourceProvider(fakeSourceId)
            .overrideWithValue(FakeCapableSource()),
      ],
      child: MaterialApp(
        home: Scaffold(
          key: scaffoldKey,
          drawer: MobileDrawer(location: '/', onNavigate: (_) {}),
          body: const SizedBox.expand(),
        ),
      ),
    ));
    scaffoldKey.currentState!.openDrawer();
    await tester.pumpAndSettle();

    final glass = tester.widget<GlassSurface>(
      find.descendant(
        of: find.byType(MobileDrawer),
        matching: find.byType(GlassSurface),
      ),
    );
    expect(
      glass.borderRadius,
      const BorderRadius.horizontal(
        right: Radius.circular(AppTheme.radiusRail),
      ),
    );
  });
}
