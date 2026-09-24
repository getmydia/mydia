/// Runs the user's macOS "Double-click a window's title bar to" action.
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
/// itself, since Flutter cannot read or replicate that preference. This is
/// that request. `WindowDragBand`'s own maximize/unmaximize toggle stays
/// unused on macOS; see `WindowTitleRow`, which wires this in as the
/// default `onBandDoubleTap` there.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'window_chrome_channel.dart';

const MethodChannel _channel = MethodChannel(kWindowChromeChannelName);

/// Fire-and-forget: called from a gesture handler, where an exception would
/// surface as a red screen mid-playback. A `MissingPluginException` is the
/// expected outcome everywhere but the real macOS app (including every
/// widget test), since nothing on those platforms answers this method.
Future<void> performMacTitleBarDoubleClick() async {
  try {
    await _channel.invokeMethod<void>('performTitleBarDoubleClick');
  } on PlatformException catch (e) {
    debugPrint('[TitleBarDoubleClick] Failed to run the native action: $e');
  } on MissingPluginException catch (e) {
    debugPrint('[TitleBarDoubleClick] Failed to run the native action: $e');
  }
}
