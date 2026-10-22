import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/domain/navigation/source_nav.dart';
import 'package:player/presentation/widgets/glass_surface.dart';
import 'package:player/presentation/widgets/nav/bottom_nav.dart';

const _home = SourceNavEntry(
  id: 'home',
  label: 'Home',
  icon: Icons.home_outlined,
  selectedIcon: Icons.home,
  route: '/s/x',
);
const _movies = SourceNavEntry(
  id: 'movies',
  label: 'Movies',
  icon: Icons.movie_outlined,
  selectedIcon: Icons.movie,
  route: '/s/x/library/movies',
);

Future<void> _pump(WidgetTester tester, {required bool liquid}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: AppTheme.build(Palettes.projectionBooth, liquid: liquid),
      home: Scaffold(
        bottomNavigationBar: BottomNav(
          location: '/s/x',
          onNavigate: (_) {},
          entries: const [_home, _movies],
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Liquid Glass: a 62 tall capsule with a 54 tall selection pill',
      (tester) async {
    await _pump(tester, liquid: true);
    final glass = find.byType(GlassSurface);
    expect(tester.getSize(glass).height, 62);
    expect(
      tester.widget<GlassSurface>(glass).borderRadius,
      BorderRadius.circular(31),
    );
    final items = find.byType(NavItem);
    expect(tester.getSize(items.first).height, 54);
    final pill = tester.widget<AnimatedContainer>(find.descendant(
      of: items.first,
      matching: find.byType(AnimatedContainer),
    ));
    final decoration = pill.decoration! as BoxDecoration;
    expect(decoration.borderRadius, BorderRadius.circular(27));
    // Inset 4 on every side of the row.
    final bar = tester.getRect(glass);
    final row = tester.getRect(items.first);
    expect(row.top - bar.top, 4);
    expect(row.left - bar.left, 4);
  });

  testWidgets('Frosted: the bar keeps its 24 point pill', (tester) async {
    await _pump(tester, liquid: false);
    expect(
      tester.widget<GlassSurface>(find.byType(GlassSurface)).borderRadius,
      BorderRadius.circular(AppTheme.radiusBottomBar),
    );
    expect(tester.getSize(find.byType(GlassSurface)).height, isNot(62));
  });
}
