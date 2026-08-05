// The player's poster depth contract (plan R7, R8, R11).
//
// Every poster-shaped surface must behave identically: a resting token shadow
// so the poster reads as an object at rest, a hover accent that only deepens
// that shadow, no lift and no scale ever, no live blur in the subtree, and a
// reduced-motion path that collapses the accent while keeping the resting
// shadow. This library holds the helpers and the reusable suite so the contract
// is asserted from one place instead of being restated per widget.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';

/// Largest scale factor applied by any [Transform] in the tree. A poster that
/// never scales keeps this at ~1.0.
double maxScale(WidgetTester tester) {
  var largest = 1.0;
  for (final t in tester.widgetList<Transform>(find.byType(Transform))) {
    final s = t.transform.getMaxScaleOnAxis();
    if (s > largest) largest = s;
  }
  return largest;
}

/// Vertical translation applied by the first [Transform] (negative = up).
double liftY(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(find.byType(Transform));
  if (transforms.isEmpty) return 0;
  return transforms.first.transform.getTranslation().y;
}

/// The poster's shadow box: the first [DecoratedBox] carrying a non-empty
/// boxShadow. Structure-agnostic on purpose, so it keeps working when the
/// widget tree is refactored underneath it.
BoxDecoration shadowDecoration(WidgetTester tester) {
  for (final d in tester.widgetList<DecoratedBox>(find.byType(DecoratedBox))) {
    final deco = d.decoration;
    if (deco is BoxDecoration &&
        deco.boxShadow != null &&
        deco.boxShadow!.isNotEmpty) {
      return deco;
    }
  }
  fail('no DecoratedBox with a boxShadow found');
}

/// Moves a synthetic mouse pointer onto [target] and settles any animation.
Future<TestGesture> hoverOver(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
  return gesture;
}

/// Hosts [child] under a [ProviderScope] and [MaterialApp].
///
/// Pass [size] to constrain the child (posters that size themselves via
/// `Expanded` need this); leave it null for widgets that carry their own
/// dimensions.
Widget posterHost(Widget child, {bool reduceMotion = false, Size? size}) {
  final body = size == null
      ? child
      : SizedBox(width: size.width, height: size.height, child: child);

  return ProviderScope(
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(body: Center(child: body)),
      ),
    ),
  );
}

/// Runs the six-point poster depth contract against the widget built by
/// [build], locating it with [target].
void runPosterDepthContract({
  required String description,
  required Widget Function() build,
  required Finder target,
  Size? size,
}) {
  group('$description poster depth contract (R7/R8/R11)', () {
    testWidgets('rests on the resting token shadow', (tester) async {
      await tester.pumpWidget(posterHost(build(), size: size));
      await tester.pumpAndSettle();

      expect(shadowDecoration(tester).boxShadow, DepthTokens.posterResting);
    });

    testWidgets('hover deepens the shadow to the hover token', (tester) async {
      await tester.pumpWidget(posterHost(build(), size: size));
      await tester.pumpAndSettle();
      await hoverOver(tester, target);

      expect(shadowDecoration(tester).boxShadow, DepthTokens.posterHover);
    });

    testWidgets('does not lift or scale at rest', (tester) async {
      await tester.pumpWidget(posterHost(build(), size: size));
      await tester.pumpAndSettle();

      expect(liftY(tester), 0);
      expect(maxScale(tester), lessThanOrEqualTo(1.001));
    });

    testWidgets('does not lift or scale on hover', (tester) async {
      await tester.pumpWidget(posterHost(build(), size: size));
      await tester.pumpAndSettle();
      await hoverOver(tester, target);

      expect(liftY(tester), 0);
      expect(maxScale(tester), lessThanOrEqualTo(1.001));
    });

    testWidgets('renders no live blur in its subtree', (tester) async {
      await tester.pumpWidget(posterHost(build(), size: size));
      await tester.pumpAndSettle();
      expect(find.byType(BackdropFilter), findsNothing);

      await hoverOver(tester, target);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets(
        'under reduced motion the hover accent collapses and the '
        'resting shadow stays', (tester) async {
      await tester.pumpWidget(
        posterHost(build(), reduceMotion: true, size: size),
      );
      await tester.pumpAndSettle();
      await hoverOver(tester, target);

      expect(liftY(tester), 0);
      expect(maxScale(tester), lessThanOrEqualTo(1.001));
      expect(shadowDecoration(tester).boxShadow, DepthTokens.posterResting);
    });
  });
}
