// U6 — solid elevated posters + hover demotion (plan R7, R11; AE1).
//
// MediaPoster is the parallel poster widget to MediaCard; it must get the same
// solid-poster treatment: a resting token shadow at rest (R7), a small hover
// lift that deepens the shadow with no 1.02 scale jump (R11), no live blur, and
// motion that collapses under reduced motion while the resting shadow stays.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/depth_tokens.dart';
import 'package:player/presentation/widgets/media_poster.dart';

import '../../test_utils/play_glyph_finders.dart';

Widget _host(Widget child, {bool reduceMotion = false}) => ProviderScope(
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            body:
                Center(child: SizedBox(width: 140, height: 230, child: child)),
          ),
        ),
      ),
    );

double _maxScale(WidgetTester tester) {
  var maxScale = 1.0;
  for (final t in tester.widgetList<Transform>(find.byType(Transform))) {
    final s = t.transform.getMaxScaleOnAxis();
    if (s > maxScale) maxScale = s;
  }
  return maxScale;
}

double _liftY(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(find.byType(Transform));
  if (transforms.isEmpty) return 0;
  return transforms.first.transform.getTranslation().y;
}

BoxDecoration _shadowDecoration(WidgetTester tester) {
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

/// The cursor declared by the card-wide hover region.
MouseCursor _cardCursor(WidgetTester tester) => tester
    .widget<MouseRegion>(
      find
          .descendant(
            of: find.byType(MediaPoster),
            matching: find.byType(MouseRegion),
          )
          .first,
    )
    .cursor;

Future<void> _hover(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
}

void main() {
  group('MediaPoster solid poster (R7/R11)', () {
    testWidgets('has a resting token shadow and no live blur at rest',
        (tester) async {
      await tester.pumpWidget(_host(const MediaPoster(title: 'Show')));
      await tester.pump();

      expect(_shadowDecoration(tester).boxShadow, DepthTokens.posterResting);
      expect(find.byType(BackdropFilter), findsNothing);
    });

    testWidgets('hover deepens the shadow with no offset or scale jump',
        (tester) async {
      await tester.pumpWidget(_host(const MediaPoster(title: 'Show')));
      await tester.pump();

      await _hover(tester, find.byType(MediaPoster));

      // No lift/offset and no scale — only the shadow firms up (R11).
      expect(_liftY(tester), 0);
      expect(_maxScale(tester), lessThanOrEqualTo(1.001));
      expect(_shadowDecoration(tester).boxShadow, DepthTokens.posterHover);
    });

    testWidgets(
        'under reduced motion the hover accent collapses; resting '
        'shadow stays', (tester) async {
      await tester.pumpWidget(
        _host(const MediaPoster(title: 'Show'), reduceMotion: true),
      );
      await tester.pump();

      await _hover(tester, find.byType(MediaPoster));

      expect(_liftY(tester), 0);
      expect(_maxScale(tester), lessThanOrEqualTo(1.001));
      expect(_shadowDecoration(tester).boxShadow, DepthTokens.posterResting);
    });

    testWidgets(
        'hover offers no play affordance, because tapping a poster '
        'opens the title rather than playing it', (tester) async {
      await tester.pumpWidget(_host(const MediaPoster(title: 'Show')));
      await tester.pump();

      expect(findPlayGlyph(), findsNothing);

      await _hover(tester, find.byType(MediaPoster));

      expect(findPlayGlyph(), findsNothing);
    });

    testWidgets(
        'the hover target covers the title, which is part of the same '
        'tap target as the poster', (tester) async {
      await tester.pumpWidget(_host(const MediaPoster(title: 'Show')));
      await tester.pump();

      await _hover(tester, find.text('Show'));

      expect(_shadowDecoration(tester).boxShadow, DepthTokens.posterHover);
    });

    testWidgets('a tappable poster offers a click cursor, an inert one defers',
        (tester) async {
      await tester.pumpWidget(_host(MediaPoster(title: 'Show', onTap: () {})));
      await tester.pump();

      expect(_cardCursor(tester), SystemMouseCursors.click);

      await tester.pumpWidget(_host(const MediaPoster(title: 'Show')));
      await tester.pump();

      expect(_cardCursor(tester), MouseCursor.defer);
    });

    testWidgets('tap fires onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(MediaPoster(title: 'Show', onTap: () => tapped = true)),
      );
      await tester.tap(find.byType(MediaPoster));
      expect(tapped, isTrue);
    });
  });
}
