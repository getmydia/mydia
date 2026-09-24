/// Reports a pointer-down on empty title-bar band space to native code, so
/// it can run the user's macOS "Double-click a window's title bar to" action
/// when appropriate.
///
/// `MainFlutterWindow.sendEvent` intercepts every double-click that lands in
/// the 40pt band `WindowTitleRow` draws its row into and hands it to Flutter
/// alone, so AppKit's own title-bar zoom never runs there. Left to itself,
/// AppKit zooms the window on *every* double-click in that band, including
/// one that lands on a Flutter control drawn there (back, cast), and it
/// zooms a second time on top of `WindowDragBand`'s own double-tap maximize
/// toggle when the click lands on empty band space, so the two fight each
/// other. Routing the click to Flutter only fixes both, but it means empty
/// band space has to ask native code to perform the System Settings action
/// itself, since Flutter cannot read or replicate that preference.
///
/// Native code, not Flutter, is also the only thing allowed to decide *when*
/// two clicks form a double-click. AppKit's `NSEvent.clickCount` is timed
/// against the user's own System Settings double-click interval, which can
/// run well past Flutter's fixed 300ms `kDoubleTapTimeout` (and
/// `kDoubleTapSlop`'s move tolerance). A `GestureDetector.onDoubleTap` that
/// has to see both clicks land inside that fixed window can silently miss a
/// double-click AppKit itself already counted, leaving the title bar action
/// looking like it does nothing. So `WindowDragBand` no longer waits for
/// Flutter's own double-tap gesture on macOS: it reports every raw
/// pointer-down on empty band space, through this function, the instant it
/// happens, and `MainFlutterWindow` decides whether it was the second half
/// of a double-click it already diverted and, if so, runs the action.
/// `WindowDragBand`'s own maximize/unmaximize toggle stays unused on macOS;
/// see `WindowTitleRow`, which wires this in as the default
/// `onBandPointerDown` there.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'window_chrome_channel.dart';

const MethodChannel _channel = MethodChannel(kWindowChromeChannelName);

/// Fire-and-forget: called from a raw pointer listener, where an exception
/// would surface as a red screen mid-playback. A `MissingPluginException` is
/// the expected outcome everywhere but the real macOS app (including every
/// widget test), since nothing on those platforms answers this method.
Future<void> reportMacTitleBarPointerDown() async {
  try {
    await _channel.invokeMethod<void>('titleBarPointerDown');
  } on PlatformException catch (e) {
    debugPrint('[TitleBarDoubleClick] Failed to report the pointer down: $e');
  } on MissingPluginException catch (e) {
    debugPrint('[TitleBarDoubleClick] Failed to report the pointer down: $e');
  }
}
