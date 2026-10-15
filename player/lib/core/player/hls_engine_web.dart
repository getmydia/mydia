/// Web implementation: load a current hls.js and let media_kit find it.
///
/// See `hls_engine.dart` for why a browser's own HLS engine cannot play a
/// Mydia session.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

// media_kit exposes no way to force hls.js, and its loader is the only thing
// that fetches it. Reaching into `src/` is deliberate: calling the loader
// first, with our own URL, is what keeps media_kit's bundled 1.4.10 off the
// page. It is idempotent and guarded by its own lock, so media_kit's later
// call returns immediately. If media_kit ever moves this file the build fails
// here, loudly, which is the point of importing it rather than copying it.
// ignore: implementation_imports
import 'package:media_kit/src/player/web/utils/hls.dart' as media_kit_hls;

import 'package:media_kit/media_kit.dart' show Player;
// `WebPlayer` is exported conditionally and the analyzer resolves it to the
// stub, which owns no element; see `subtitle_cues_web.dart`.
// ignore: implementation_imports
import 'package:media_kit/src/player/web/player/real.dart' as media_kit_web;
import 'package:web/web.dart' as web;

import 'hls_engine.dart';

@JS('HTMLMediaElement')
external JSObject? get _htmlMediaElement;

@JS('Hls')
external JSObject? get _hls;

@JS('document.createElement')
external JSObject _createElement(String tagName);

/// Whether hls.js is loaded and says it can run here.
///
/// `Hls.isSupported()` is the library's own answer, and it is the one that
/// matters: it checks for `MediaSource` or, since 1.5, the `ManagedMediaSource`
/// that iOS 17.1+ gives every browser on iPhone. Read on each call rather than
/// cached, so the answer describes whichever hls.js actually ended up on the
/// page.
bool _hlsJsUsable() {
  final hls = _hls;
  if (hls == null) return false;
  try {
    final isSupported = hls.getProperty<JSFunction?>('isSupported'.toJS);
    if (isSupported == null) return false;
    return isSupported.callAsFunction(hls).dartify() == true;
  } catch (_) {
    return false;
  }
}

bool _installed = false;

@JS('WeakMap')
extension type _WeakMap._(JSObject _) implements JSObject {
  external _WeakMap();
  external JSArray<JSObject>? get(JSObject key);
  external void set(JSObject key, JSArray<JSObject> value);
  external bool delete(JSObject key);
}

/// Every hls.js instance media_kit attached, by the element it attached to.
/// Weak, so a dropped element takes its list with it.
final _WeakMap _hlsByMedia = _WeakMap();

/// Marks a prototype whose `attachMedia` is already wrapped. On the prototype,
/// not in a Dart flag, because a different `Hls` (a reload of hls.js, a test's
/// stub) brings a fresh prototype that needs wrapping too.
const String _trackedMarker = '__mydiaTracksAttachMedia';

/// Wraps `Hls.prototype.attachMedia` to record each instance against its
/// media element, so [releaseHlsOnElement] can find what media_kit dropped.
///
/// The prototype, for the same reason as the `canPlayType` override: media_kit
/// builds its `Hls` privately and hands it to nobody. The wrapper forwards
/// every call unchanged. Idempotent per prototype; does nothing when hls.js
/// is not on the page.
void _installAttachTracker() {
  final hls = _hls;
  if (hls == null) return;
  final prototype = hls.getProperty<JSObject?>('prototype'.toJS);
  if (prototype == null) return;
  if (prototype.has(_trackedMarker)) return;
  final original = prototype.getProperty<JSFunction?>('attachMedia'.toJS);
  if (original == null) return;

  JSAny? wrapper(JSObject self, JSAny? media) {
    if (media.isA<JSObject>()) {
      final element = media as JSObject;
      final list = _hlsByMedia.get(element) ?? JSArray<JSObject>();
      list.callMethod<JSAny?>('push'.toJS, self);
      _hlsByMedia.set(element, list);
    }
    return original.callAsFunction(self, media);
  }

  prototype.setProperty('attachMedia'.toJS, wrapper.toJSCaptureThis);
  prototype.setProperty(_trackedMarker.toJS, true.toJS);
}

/// Destroys every hls.js instance recorded for [element], forgets them, and
/// pauses [element]. Never throws: one instance failing to destroy must not
/// spare the others or stop the caller's teardown.
void releaseHlsOnElement(web.HTMLMediaElement element) {
  final list = _hlsByMedia.get(element);
  _hlsByMedia.delete(element);
  if (list != null) {
    for (final hls in list.toDart) {
      try {
        hls.callMethod<JSAny?>('destroy'.toJS);
      } catch (_) {
        // Keep going: the rest still need destroying.
      }
    }
  }
  try {
    element.pause();
  } catch (_) {
    // Nothing more to do for an element that will not pause.
  }
}

void releaseHlsEngine(Player player) {
  final platform = player.platform;
  if (platform is! media_kit_web.WebPlayer) return;
  releaseHlsOnElement(platform.element);
}

/// Replaces `HTMLMediaElement.prototype.canPlayType` with a wrapper that
/// answers `''` for HLS content types while hls.js can run.
///
/// The prototype, not one element: media_kit creates its `<video>` inside the
/// `Player` constructor and hands it out to nobody, so there is no instance to
/// reach. Every other type is forwarded to the original.
///
/// The original is invoked against a detached `<video>` created before the
/// patch, rather than against the caller's element. `canPlayType` answers from
/// the browser's codec tables and not from element state, so the answer is the
/// same either way, and a fixed receiver keeps the wrapper a plain function.
void _installNativeHlsOverride() {
  if (_installed) return;

  final mediaElement = _htmlMediaElement;
  if (mediaElement == null) return;

  final prototype = mediaElement.getProperty<JSObject?>('prototype'.toJS);
  if (prototype == null) return;

  final original = prototype.getProperty<JSFunction?>('canPlayType'.toJS);
  if (original == null) return;

  final probe = _createElement('video');

  String wrapper(String contentType) {
    if (hidesNativeHls(contentType, hlsJsUsable: _hlsJsUsable())) return '';
    final answer = original.callAsFunction(probe, contentType.toJS);
    return (answer?.dartify() as String?) ?? '';
  }

  prototype.setProperty('canPlayType'.toJS, wrapper.toJS);
  _installed = true;
}

Future<void> prepareHlsEngine() async {
  try {
    await media_kit_hls.HLS.ensureInitialized(hls: kVendoredHlsJsUrl);
  } catch (_) {
    // `ensureInitialized` already swallows a failed load; this only guards
    // against it changing its mind. Falling through leaves the browser's own
    // engine in place, which is what shipped before this existed.
  }
  _installNativeHlsOverride();
  _installAttachTracker();
}
