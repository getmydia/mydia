/// How this build can present the player fullscreen.
///
/// Resolved once per `FullscreenController`. [osWindow] and [systemUi] do not
/// change which platform call the native backend makes — media_kit's helper
/// branches internally on `Platform.isAndroid || Platform.isIOS`
/// (`media_kit_video/lib/src/video/video_texture.dart:479`). The distinction
/// exists only to decide whether the controller's state can be event-sourced.
enum FullscreenMode {
  /// Native desktop. The OS window goes fullscreen and `windowFullscreen`
  /// reports it, so state is authoritative.
  osWindow,

  /// Native mobile. `SystemChrome.setEnabledSystemUIMode` has no callback, so
  /// this is the one mode whose state is necessarily optimistic.
  systemUi,

  /// Web with the standard Fullscreen API. Mydia's own chrome survives, which
  /// is why this is preferred wherever it works.
  documentElement,

  /// WebKit builds that implement fullscreen only for `HTMLVideoElement`.
  /// Apple draws the chrome and everything Flutter draws is unreachable until
  /// the viewer exits.
  ///
  /// This is no longer reachable from the probes alone on a current iPhone.
  /// Safari 16.4 unprefixed the Fullscreen API on iPadOS and 17.2 brought it to
  /// iPhone, so `document.fullscreenEnabled` now answers true there and
  /// [documentElement] wins at construction. [demoteWebMode] is what brings
  /// this route back, after the document route has actually been refused.
  nativeVideoElement,

  /// No fullscreen route at all. The button is hidden rather than left dead.
  unsupported,
}

/// Picks the web mode from two capability probes.
///
/// Deliberately NOT annotated `@visibleForTesting`, unlike its cousins
/// `PlatformFeatures.computeSupportsKeyboardShortcuts` and
/// `windowChromeInsetFor`. Those are called from inside their own library
/// file; this one is called from `fullscreen_backend_web.dart`, and the
/// annotation fires `invalid_use_of_visible_for_testing_member` across files.
/// `windowFullscreenSignal` in `core/window/window_fullscreen.dart` documents
/// the same trap and skips the annotation for the same reason.
///
/// [documentFullscreenEnabled] must come from `document.fullscreenEnabled`,
/// not from probing for a `requestFullscreen` method. That property is also
/// false inside an iframe without `allow="fullscreen"`, which is the other
/// case that has to fall back, so one read covers both.
///
/// [videoElementFullscreenSupported] must be probed on
/// `HTMLVideoElement.prototype`, never on a live element:
/// `video.webkitSupportsFullscreen` stays false until metadata loads, and the
/// button has to decide whether to exist before then.
FullscreenMode resolveWebMode({
  required bool documentFullscreenEnabled,
  required bool videoElementFullscreenSupported,
}) {
  if (documentFullscreenEnabled) return FullscreenMode.documentElement;
  if (videoElementFullscreenSupported) {
    return FullscreenMode.nativeVideoElement;
  }
  return FullscreenMode.unsupported;
}

/// The route to use after [current] has been refused at request time.
///
/// [resolveWebMode] answers from capability probes, which is all that is
/// available before anything has been asked. This answers from what actually
/// happened, which is the only thing that settles WebKit: on a current iPhone
/// `document.fullscreenEnabled` is true, so [FullscreenMode.documentElement]
/// wins at construction, and if that request is then refused the video element
/// route is still there and still works.
///
/// Demotion is one-way for the session on purpose. Re-promoting after a single
/// success would let the mode oscillate and make the diagnostics readout
/// useless for the thing it exists to answer.
///
/// Refusing the video element route returns [FullscreenMode.unsupported], which
/// withdraws the control. That is a deliberate trade: a `webkitEnterFullscreen`
/// throw can be transient (WebKit refuses before the video has metadata), so
/// this can retire a route that would have worked on a later tap. A control that
/// is present and inert is the defect being fixed, and a control that is honest
/// about having failed is the lesser harm.
FullscreenMode demoteWebMode({
  required FullscreenMode current,
  required bool videoElementFullscreenSupported,
}) {
  switch (current) {
    case FullscreenMode.documentElement:
      return videoElementFullscreenSupported
          ? FullscreenMode.nativeVideoElement
          : FullscreenMode.unsupported;
    case FullscreenMode.nativeVideoElement:
      return FullscreenMode.unsupported;
    case FullscreenMode.osWindow:
    case FullscreenMode.systemUi:
    case FullscreenMode.unsupported:
      return current;
  }
}
