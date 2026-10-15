import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/detail_art_image.dart' show ArtSlot;
import 'package:player/presentation/screens/detail/detail_hero.dart';
import 'package:player/presentation/widgets/shell_rail_inset.dart';

const _overlayKey = Key('overlay');

Widget _hero({double? inset}) {
  final hero = Builder(
    builder: (context) => const SizedBox(
      width: 1000,
      height: 400,
      child: DetailHeroBackground(
        art: null,
        slot: ArtSlot.backdrop,
        overlay: SizedBox(key: _overlayKey, width: 100, height: 40),
      ),
    ),
  );
  return MaterialApp(
    home: Scaffold(
      body: inset == null ? hero : ShellRailInset(left: inset, child: hero),
    ),
  );
}

void main() {
  testWidgets('the hero title block sits beside the rail, the art does not',
      (tester) async {
    await tester.pumpWidget(_hero(inset: 88));
    expect(tester.getTopLeft(find.byKey(_overlayKey)).dx, 20 + 88);
    expect(tester.getTopLeft(find.byType(DetailHeroBackground)).dx, 0);
  });

  testWidgets('with no rail (phone layout) nothing moves', (tester) async {
    await tester.pumpWidget(_hero());
    expect(tester.getTopLeft(find.byKey(_overlayKey)).dx, 20);
  });

  testWidgets('ShellPageInset and SliverRailInset inset by the rail',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ShellRailInset(
          left: 88,
          child: Scaffold(
            body: Column(
              children: [
                const ShellPageInset(
                  child: SizedBox(
                    key: Key('box'),
                    width: double.infinity,
                    height: 10,
                  ),
                ),
                Expanded(
                  child: CustomScrollView(
                    slivers: railInsetSlivers(const [
                      SliverToBoxAdapter(
                        child: SizedBox(key: Key('a'), height: 10),
                      ),
                    ]),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(tester.getTopLeft(find.byKey(const Key('box'))).dx, 88);
    expect(tester.getTopLeft(find.byKey(const Key('a'))).dx, 88);
  });

  testWidgets('the inset is zero outside the shell', (tester) async {
    double? seen;
    await tester.pumpWidget(Builder(builder: (context) {
      seen = ShellRailInset.of(context);
      return const SizedBox();
    }));
    expect(seen, 0);
  });
}
