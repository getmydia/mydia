// Runs only under `flutter test --platform chrome`: it drives a browser
// prototype patch and a real `<video>`.
@TestOn('browser')
// Out of very_good's bundle: it compiles every bundled file for the VM, and
// this one imports browser-only libraries. `Run browser tests` covers it.
@Tags(['skip_very_good_optimization'])
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/hls_engine.dart';
import 'package:player/core/player/hls_engine_web.dart'
    show releaseHlsOnElement;
import 'package:web/web.dart' as web;

@JS('window')
external JSObject get _window;

JSAny? _eval(String source) =>
    _window.callMethod<JSAny?>('eval'.toJS, source.toJS);

/// A stand-in for hls.js. Defined in JS because the patch under test wraps a
/// prototype method, which a Dart object has no way to offer.
JSFunction _installStubHls() {
  final hls = _eval('''
(function () {
  function Hls() { this.destroyed = 0; this.media = null; }
  Hls.isSupported = function () { return true; };
  Hls.prototype.attachMedia = function (media) { this.media = media; };
  Hls.prototype.destroy = function () {
    this.destroyed += 1;
    this.media = null;
  };
  return Hls;
})()
''')! as JSFunction;
  _window.setProperty('Hls'.toJS, hls);
  return hls;
}

JSObject _attach(JSFunction hls, web.HTMLMediaElement media) {
  final instance = hls.callAsConstructor<JSObject>();
  instance.callMethod<JSAny?>('attachMedia'.toJS, media);
  return instance;
}

int _destroyed(JSObject instance) =>
    instance.getProperty<JSNumber>('destroyed'.toJS).toDartInt;

web.HTMLVideoElement _video() => web.HTMLVideoElement();

void main() {
  late JSFunction hls;

  setUp(() async {
    // A fresh class per test, so each one starts with an unpatched prototype
    // and nothing recorded.
    hls = _installStubHls();
    await prepareHlsEngine();
  });

  test('attachMedia still reaches hls.js', () {
    final video = _video();
    final instance = _attach(hls, video);

    // `strictEquals`, not `same`: identity of interop values is a JS question.
    expect(
      instance.getProperty<JSAny?>('media'.toJS).strictEquals(video).toDart,
      isTrue,
    );
  });

  test('destroys every hls.js attached to the element, and only those', () {
    final video = _video();
    final other = _video();
    final first = _attach(hls, video);
    final second = _attach(hls, video);
    final unrelated = _attach(hls, other);

    releaseHlsOnElement(video);

    expect(_destroyed(first), 1);
    expect(_destroyed(second), 1);
    expect(_destroyed(unrelated), 0);
  });

  test('an instance attached twice is destroyed once', () {
    final video = _video();
    final instance = _attach(hls, video);
    instance.callMethod<JSAny?>('attachMedia'.toJS, video);

    releaseHlsOnElement(video);

    expect(_destroyed(instance), 1);
  });

  test('pauses the element', () {
    final video = _video();
    var pauses = 0;
    video.setProperty(
        'pause'.toJS,
        (() {
          pauses++;
        }).toJS);

    releaseHlsOnElement(video);

    expect(pauses, 1);
  });

  test('a second release destroys nothing again', () {
    final video = _video();
    final instance = _attach(hls, video);

    releaseHlsOnElement(video);
    releaseHlsOnElement(video);

    expect(_destroyed(instance), 1);
  });

  test('preparing twice does not record an instance twice', () async {
    await prepareHlsEngine();
    final video = _video();
    final instance = _attach(hls, video);

    releaseHlsOnElement(video);

    expect(_destroyed(instance), 1);
  });

  test('a destroy that throws does not stop the rest', () {
    final video = _video();
    final broken = _attach(hls, video);
    broken.setProperty(
      'destroy'.toJS,
      _eval('(function () { throw new Error("boom"); })'),
    );
    final healthy = _attach(hls, video);
    var pauses = 0;
    video.setProperty(
        'pause'.toJS,
        (() {
          pauses++;
        }).toJS);

    expect(() => releaseHlsOnElement(video), returnsNormally);
    expect(_destroyed(healthy), 1);
    expect(pauses, 1);
  });

  test('an element nothing attached to is only paused', () {
    final video = _video();
    var pauses = 0;
    video.setProperty(
        'pause'.toJS,
        (() {
          pauses++;
        }).toJS);

    expect(() => releaseHlsOnElement(video), returnsNormally);
    expect(pauses, 1);
  });

  test('without hls.js on the page, release still pauses', () async {
    _window.delete('Hls'.toJS);
    await prepareHlsEngine();
    final video = _video();
    var pauses = 0;
    video.setProperty(
        'pause'.toJS,
        (() {
          pauses++;
        }).toJS);

    expect(() => releaseHlsOnElement(video), returnsNormally);
    expect(pauses, 1);
  });
}
