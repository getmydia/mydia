// Shared finders for the "play means play" rule: a play glyph may only appear
// on a surface where activating it actually starts playback. Poster cards in
// grids and rails open the title instead, so they must never render one.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The glyphs the player uses to promise playback.
///
/// Type/section icons such as `Icons.playlist_play_rounded` are deliberately
/// absent: they label a result, they do not offer to play it.
const playGlyphs = <IconData>[
  Icons.play_arrow,
  Icons.play_arrow_rounded,
  Icons.play_circle,
  Icons.play_circle_rounded,
  Icons.play_circle_filled,
  Icons.play_circle_filled_rounded,
  Icons.play_circle_fill_rounded,
  Icons.play_circle_outline,
  Icons.play_circle_outline_rounded,
];

/// Matches any play-affordance glyph in the tree.
Finder findPlayGlyph() => find.byWidgetPredicate(
      (widget) => widget is Icon && playGlyphs.contains(widget.icon),
      description: 'play affordance glyph',
    );

/// Moves a mouse pointer onto [target] and settles, so hover-only chrome has
/// rendered by the time the caller asserts.
Future<void> hoverOver(WidgetTester tester, Finder target) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await gesture.moveTo(tester.getCenter(target));
  await tester.pumpAndSettle();
}
