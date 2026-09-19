// Runs only under `flutter test --platform chrome`: the override this covers
// rewrites a browser prototype, and hls_engine_web.dart is not reachable from
// a VM test run at all.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/hls_engine.dart';

@JS('window')
external JSObject get _window;

@JS('document.createElement')
external JSObject _createElement(String tagName);

String _canPlayType(String contentType) {
  final video = _createElement('video');
  final answer = video.callMethod<JSString?>(
    'canPlayType'.toJS,
    contentType.toJS,
  );
  return answer?.toDart ?? '';
}

void _setHlsSupport({required bool supported}) {
  final stub = JSObject();
  stub.setProperty('isSupported'.toJS, (() => supported.toJS).toJS);
  _window.setProperty('Hls'.toJS, stub);
}

void main() {
  // The test server does not serve `web/`, so the vendored hls.js 404s here
  // and `Hls` is whatever these tests put on the window. That is the point:
  // every assertion below is about the override's own decision, and the one
  // thing it cannot cover — the real file loading — is covered by playing a
  // resumed session in a browser, which is how this bug was found.
  setUpAll(() async {
    expect(
      _canPlayType('application/vnd.apple.mpegurl'),
      isNotEmpty,
      reason: 'Chromium claims native HLS, which is what media_kit acts on',
    );
    await prepareHlsEngine();
  });

  test('leaves the browser alone while hls.js cannot run', () {
    _setHlsSupport(supported: false);

    expect(
      _canPlayType('application/vnd.apple.mpegurl'),
      isNotEmpty,
      reason: 'with no usable hls.js the browser engine is the only one left',
    );
  });

  test('hides native HLS once hls.js can run', () {
    _setHlsSupport(supported: true);

    expect(_canPlayType('application/vnd.apple.mpegurl'), isEmpty);
    expect(_canPlayType('application/x-mpegurl'), isEmpty);
  });

  test('re-reads hls.js support on every call', () {
    // The override is installed once per page but decides per call, so a
    // browser that loads hls.js after the first question still gets it.
    _setHlsSupport(supported: true);
    expect(_canPlayType('application/vnd.apple.mpegurl'), isEmpty);

    _setHlsSupport(supported: false);
    expect(_canPlayType('application/vnd.apple.mpegurl'), isNotEmpty);
  });

  test('forwards every other content type to the browser', () {
    _setHlsSupport(supported: true);

    expect(_canPlayType('video/mp4; codecs="avc1.640028"'), isNotEmpty);
    expect(_canPlayType('video/webm'), isNotEmpty);
    expect(_canPlayType('video/mp4; codecs="nonsense"'), isEmpty);
  });
}
