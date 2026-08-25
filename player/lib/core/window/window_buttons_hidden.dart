import 'package:flutter/foundation.dart';

/// Whether the window's close/minimize/maximize buttons are currently
/// suppressed, which the player does while its playback chrome is hidden.
///
/// Deliberately platform-free, mirroring `window_fullscreen.dart`: this file
/// imports nothing that `window_manager` or a `MethodChannel` touches, so the
/// Flutter-drawn Linux buttons can watch it without a conditional import,
/// while macOS reads the same signal from its native bridge.
///
/// `setWindowButtonsHidden` in `window_buttons_bridge*.dart` is the only
/// intended writer. Deliberately NOT marked `@visibleForTesting`: that
/// annotation fires `invalid_use_of_visible_for_testing_member` as soon as
/// the bridge, which lives in a different library file, touches it.
final ValueNotifier<bool> windowButtonsHiddenSignal =
    ValueNotifier<bool>(false);

/// Read-only view of [windowButtonsHiddenSignal] for consumers.
ValueListenable<bool> get windowButtonsHidden => windowButtonsHiddenSignal;
