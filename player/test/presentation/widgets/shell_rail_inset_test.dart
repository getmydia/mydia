import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderClipRect;
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

  testWidgets('the ground strip and art paint left of the padded column',
      (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: ShellRailInset(
          left: 88,
          child: Padding(
            padding: EdgeInsets.only(left: 88),
            child: RailBleed(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: -88,
                    top: 0,
                    width: 88,
                    height: 50,
                    child: ColoredBox(
                      key: Key('strip'),
                      color: Color(0xFF123456),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.getTopLeft(find.byKey(const Key('strip'))).dx, 0);
    // The clip lets it through on the left, by exactly the inset.
    final clip = tester.renderObject<RenderClipRect>(find.byType(ClipRect));
    expect(clip.clipper!.getClip(const Size(500, 500)).left, -88);
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
