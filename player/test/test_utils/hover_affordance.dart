// What a poster surface is allowed to offer on hover.
//
// The rule: a play glyph may only appear where activating it actually starts
// playback. Poster cards in the grids and rails open the title instead, so they
// offer a click cursor over their tap target and no glyph at all.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The glyphs the player uses to promise playback.
///
/// Type and section icons such as `Icons.playlist_play_rounded` are
/// deliberately absent: they label a result, they do not offer to play it.
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

/// The cursor declared by the outermost hover region inside [of].
///
/// `.first` is the outermost match in tree order, which is the region wrapping
/// the card's whole tap target rather than the one `PosterFrame` keeps for its
/// own depth accent. That outer region is what decides the cursor anywhere on
/// the card, title included, since `PosterFrame` sets no cursor of its own.
MouseCursor hoverCursor(WidgetTester tester, {required Finder of}) => tester
    .widget<MouseRegion>(
      find.descendant(of: of, matching: find.byType(MouseRegion)).first,
    )
    .cursor;
