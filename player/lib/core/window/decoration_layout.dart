/// Parses GTK's `gtk-decoration-layout` into the buttons each side of the
/// window carries.
///
/// The rules mirror GTK's own parser in `gtk/gtkheaderbar.c` (3.24.52, around
/// line 330), because anything else puts buttons where the user's desktop
/// does not expect them:
///
///   * `g_strsplit(layout, ":", 2)` splits on the FIRST colon only. A second
///     colon stays inside the end side's token list, where it stops any
///     token containing it from being recognised.
///   * `if (tokens[i] == NULL) break` means a string with no colon at all
///     puts every button on the START side. This is the rule most likely to
///     be got backwards, so it has its own test.
///   * GTK recognises `icon`, `menu`, `minimize`, `maximize` and `close`.
///     Everything else is dropped in silence, including `appmenu`, which
///     appears in GNOME's own default of `appmenu:close`.
///
/// Sides are named start and end rather than left and right so that
/// rendering through Flutter's `Directionality` mirrors under RTL, which is
/// what GTK does by consulting `gtk_widget_get_direction`.
library;

import 'package:flutter/foundation.dart';

/// A window button this app knows how to draw.
///
/// GTK's `icon` and `menu` tokens are deliberately absent: the player has no
/// app menu and no titlebar icon, so both parse to nothing.
enum WindowButton { minimize, maximize, close }

/// Which buttons sit on each side of the window.
@immutable
class DecorationLayout {
  const DecorationLayout({required this.start, required this.end});

  /// Buttons on the leading side, which is the left under LTR.
  final List<WindowButton> start;

  /// Buttons on the trailing side, which is the right under LTR.
  final List<WindowButton> end;

  bool get isEmpty => start.isEmpty && end.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is DecorationLayout &&
      listEquals(other.start, start) &&
      listEquals(other.end, end);

  @override
  int get hashCode => Object.hash(Object.hashAll(start), Object.hashAll(end));

  @override
  String toString() => 'DecorationLayout(start: $start, end: $end)';
}

/// The layout used when the channel is unavailable, or when the string it
/// returns names no button this app draws.
///
/// All three buttons on the end side, which is the KDE and Cinnamon default.
/// It is the widest-compatible choice and never strands a user with no way
/// to minimize.
const String kFallbackDecorationLayout = ':minimize,maximize,close';

/// Parses [raw] into a layout, falling back when it names nothing drawable.
///
/// The fallback on a parsed-but-empty layout is a deliberate divergence from
/// GTK, which would render a header bar with no buttons at all. A GTK app in
/// that state still has the window manager's right-click title bar menu as an
/// escape hatch. This app undecorates the window, so that menu is gone, and a
/// window with no buttons would have no pointer-driven way to close it.
DecorationLayout parseDecorationLayout(String raw) {
  final parsed = _parse(raw);
  return parsed.isEmpty ? _parse(kFallbackDecorationLayout) : parsed;
}

DecorationLayout _parse(String raw) {
  // Split on the first colon only, matching g_strsplit(layout, ":", 2): the
  // remainder, further colons and all, is the end side.
  final sides = raw.split(':');
  final startTokens = sides.first;
  final endTokens = sides.length > 1 ? sides.sublist(1).join(':') : '';

  return DecorationLayout(
    start: _parseSide(startTokens),
    end: _parseSide(endTokens),
  );
}

List<WindowButton> _parseSide(String tokens) {
  final buttons = <WindowButton>[];
  for (final token in tokens.split(',')) {
    final button = _buttonFor(token.trim());
    if (button != null) buttons.add(button);
  }
  return List.unmodifiable(buttons);
}

/// A fixed switch rather than a lookup over `WindowButton.values`.
///
/// A name-based lookup either throws or invents a value for input this app
/// does not draw, and this input is a user-editable settings string. Every
/// unrecognised token must parse to nothing.
WindowButton? _buttonFor(String token) => switch (token) {
      'minimize' => WindowButton.minimize,
      'maximize' => WindowButton.maximize,
      'close' => WindowButton.close,
      _ => null,
    };
