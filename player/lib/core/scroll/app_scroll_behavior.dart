import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// The app's scroll behavior.
///
/// Flutter's stock [ScrollBehavior.dragDevices] omits [PointerDeviceKind.mouse],
/// on the reasoning that a desktop user scrolls with a wheel rather than by
/// grabbing content. That leaves the horizontal rails unreachable for anyone on
/// a plain mouse, because a vertical wheel does not move a horizontal axis
/// either. Adding mouse here makes grab-and-drag work on every scrollable in
/// the app.
///
/// Spread over `super.dragDevices` rather than listing the set literally, so a
/// future Flutter that adds a device kind does not silently lose it here.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        ...super.dragDevices,
        PointerDeviceKind.mouse,
      };
}
