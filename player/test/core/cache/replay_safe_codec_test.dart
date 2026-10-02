import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/replay_safe_codec.dart';

class _Frame implements ui.FrameInfo {
  _Frame(this.image);

  @override
  final ui.Image image;

  @override
  Duration get duration => const Duration(milliseconds: 40);
}

/// Hands out a fresh handle to [image] on every call and counts the calls.
class _FakeCodec implements ui.Codec {
  _FakeCodec(this.image, {this.frameCount = 1});

  final ui.Image image;
  int calls = 0;
  bool disposed = false;
  Object? failNext;
  Completer<void>? gate;

  @override
  final int frameCount;

  @override
  int get repetitionCount => 0;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    calls += 1;
    final wait = gate;
    if (wait != null) await wait.future;
    final failure = failNext;
    if (failure != null) {
      failNext = null;
      throw failure;
    }
    return _Frame(image.clone());
  }

  @override
  void dispose() => disposed = true;
}

void main() {
  late ui.Image source;

  setUp(() async {
    // Uncached, so the handle counts below see only this test's handles.
    source = await createTestImage(width: 4, height: 6, cache: false);
  });

  tearDown(() => source.dispose());

  test('later frames never reach the delegate', () async {
    final delegate = _FakeCodec(source);
    final codec = ReplaySafeCodec(delegate);

    final first = await codec.getNextFrame();
    final second = await codec.getNextFrame();
    final third = await codec.getNextFrame();

    expect(delegate.calls, 1);
    for (final frame in [first, second, third]) {
      expect(frame.image.isCloneOf(source), isTrue);
      expect(frame.duration, const Duration(milliseconds: 40));
      frame.image.dispose();
    }
    codec.dispose();
  });

  test('each caller owns its handle', () async {
    final codec = ReplaySafeCodec(_FakeCodec(source));

    final first = await codec.getNextFrame();
    first.image.dispose();
    final second = await codec.getNextFrame();

    expect(second.image.debugDisposed, isFalse);
    expect(second.image.width, 4);
    second.image.dispose();
    codec.dispose();
  });

  test('concurrent first calls share one delegate call', () async {
    final delegate = _FakeCodec(source)..gate = Completer<void>();
    final codec = ReplaySafeCodec(delegate);

    final a = codec.getNextFrame();
    final b = codec.getNextFrame();
    delegate.gate!.complete();
    final frames = await Future.wait([a, b]);

    expect(delegate.calls, 1);
    for (final frame in frames) {
      frame.image.dispose();
    }
    codec.dispose();
  });

  test('multi-frame codecs are forwarded every time', () async {
    final delegate = _FakeCodec(source, frameCount: 3);
    final codec = ReplaySafeCodec(delegate);

    (await codec.getNextFrame()).image.dispose();
    (await codec.getNextFrame()).image.dispose();

    expect(delegate.calls, 2);
    expect(codec.frameCount, 3);
    codec.dispose();
  });

  test('a failed first decode is retried on the next call', () async {
    final delegate = _FakeCodec(source)..failNext = StateError('boom');
    final codec = ReplaySafeCodec(delegate);

    await expectLater(codec.getNextFrame(), throwsStateError);
    final frame = await codec.getNextFrame();

    expect(delegate.calls, 2);
    frame.image.dispose();
    codec.dispose();
  });

  test('dispose releases the delegate and the kept frame', () async {
    final delegate = _FakeCodec(source);
    final codec = ReplaySafeCodec(delegate);
    final frame = await codec.getNextFrame();
    frame.image.dispose();

    codec.dispose();

    expect(delegate.disposed, isTrue);
    // Only the test's own handle to the source is left.
    expect(source.debugGetOpenHandleStackTraces(), hasLength(1));
  });

  test('dispose during the first decode drops the frame when it lands',
      () async {
    final delegate = _FakeCodec(source)..gate = Completer<void>();
    final codec = ReplaySafeCodec(delegate);

    final pending = codec.getNextFrame();
    codec.dispose();
    delegate.gate!.complete();

    await expectLater(pending, throwsStateError);
    expect(source.debugGetOpenHandleStackTraces(), hasLength(1));
  });

  test('replaySafeDecode wraps the codec the decoder returns', () async {
    final delegate = _FakeCodec(source);
    Future<ui.Codec> decode(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) async =>
        delegate;
    final ImageDecoderCallback wrapped = replaySafeDecode(decode);
    final buffer = await ui.ImmutableBuffer.fromUint8List(
      Uint8List.fromList(const [0]),
    );

    final codec = await wrapped(buffer);

    expect(codec, isA<ReplaySafeCodec>());
    (await codec.getNextFrame()).image.dispose();
    (await codec.getNextFrame()).image.dispose();
    expect(delegate.calls, 1);
    codec.dispose();
    buffer.dispose();
  });
}
