import 'fullscreen_failure.dart';

/// The browser calls [WebFullscreenCore] needs, behind a seam.
///
/// This file deliberately imports nothing from `package:web`. That is the whole
/// point: `fullscreen_backend_web.dart` compiles only under
/// `dart.library.js_interop`, so nothing in it can be reached from
/// `flutter test`, which always runs non-web. Everything worth testing (route
/// selection, demotion, readiness, rebinding, which failures are reported) is
/// on this side of the seam and runs on the VM against a fake. What stays on
/// the far side is the `package:web` calls themselves, and it stays thin enough
/// to read.
///
/// The same reasoning as `resolveWebMode`, `PlatformFeatures.
/// computeSupportsKeyboardShortcuts` and `windowChromeInsetFor`, applied to
/// state rather than to a single pure decision.
abstract interface class WebFullscreenPlatform {
  /// `document.fullscreenEnabled`. False when the read threw, in which case the
  /// reason is in [probeFailures].
  bool get documentFullscreenEnabled;

  /// Whether `HTMLVideoElement.prototype` carries `webkitEnterFullscreen`.
  /// False when the probe threw, in which case the reason is in
  /// [probeFailures].
  bool get videoElementFullscreenSupported;

  /// Anything that went wrong while answering the two probes above. Read once,
  /// at construction. Empty on a healthy browser.
  List<FullscreenFailure> get probeFailures;

  void listenDocumentFullscreen(void Function(bool fullscreen) onChange);

  void stopListeningDocumentFullscreen();

  /// Synchronous by contract: the call must happen on the tap frame, because
  /// user activation does not survive an await. [onRejected] fires later, off
  /// the returned promise.
  void requestDocumentFullscreen(void Function(Object error) onRejected);

  void exitDocumentFullscreen(void Function(Object error) onRejected);

  /// Binds the media element behind [player] and subscribes to its own
  /// fullscreen transitions.
  ///
  /// Returns null on success, or the cause when there is no element to bind.
  /// Any element bound by a previous call is released first.
  FullscreenFailureCause? bindVideo(
    Object player, {
    required void Function(bool fullscreen) onChange,
  });

  /// Releases the currently bound element, if any. Safe to call when nothing is
  /// bound.
  void unbindVideo();

  /// Throws when the browser refuses.
  void enterVideoFullscreen();

  /// Throws when the browser refuses.
  void exitVideoFullscreen();
}
