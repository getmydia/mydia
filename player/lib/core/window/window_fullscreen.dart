import 'package:flutter/foundation.dart';

/// Whether the OS window is in native fullscreen.
///
/// Deliberately platform-free: this file imports nothing that `window_manager`
/// touches, so widgets on every target — including web, where `window_manager`
/// has no implementation — can read it without a conditional import. The half
/// that actually talks to the window lives in
/// `window_fullscreen_controller.dart`, reachable only from
/// `desktop_window_native.dart`.
///
/// Off desktop nothing ever writes to it and it stays `false`, which is the
/// correct answer there: a platform with no window cannot be fullscreen in
/// the sense the chrome inset cares about.
///
/// `WindowFullscreenController` is the only intended writer. Deliberately NOT
/// marked `@visibleForTesting`: that annotation fires
/// `invalid_use_of_visible_for_testing_member` as soon as the controller —
/// which lives in a different library file — touches it, and tests do not need
/// it anyway, since both the controller and `WindowChromeInset` accept an
/// injected notifier.
final ValueNotifier<bool> windowFullscreenSignal = ValueNotifier<bool>(false);

/// Read-only view of [windowFullscreenSignal] for consumers.
ValueListenable<bool> get windowFullscreen => windowFullscreenSignal;
