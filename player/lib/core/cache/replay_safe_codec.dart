import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// A [ui.Codec] whose single frame can be asked for any number of times.
///
/// On web, browsers without a stable `ImageDecoder` (Firefox, Safari) decode
/// through one `<img>` element, and the engine clears that element once the
/// first frame has been resized or released. An image stream completer asks
/// the same codec for its frame again whenever it regains a listener, which
/// is every time artwork scrolls back into view. The second answer comes from
/// the emptied element: Firefox paints it black, Safari fails to load it.
///
/// This keeps the first frame and hands out clones, so the engine codec is
/// asked exactly once. Animated images are forwarded untouched; their decoder
/// is safe to call repeatedly.
class ReplaySafeCodec implements ui.Codec {
  ReplaySafeCodec(this._delegate);

  final ui.Codec _delegate;
  Future<ui.FrameInfo>? _first;
  ui.Image? _kept;
  bool _disposed = false;

  @override
  int get frameCount => _delegate.frameCount;

  @override
  int get repetitionCount => _delegate.repetitionCount;

  @override
  Future<ui.FrameInfo> getNextFrame() async {
    if (_delegate.frameCount > 1) return _delegate.getNextFrame();

    final pending = _first ??= _decodeOnce();
    final ui.FrameInfo frame;
    try {
      frame = await pending;
    } catch (_) {
      // Let the next caller try the delegate again.
      if (identical(_first, pending)) _first = null;
      rethrow;
    }
    if (_disposed) throw StateError('Codec has been disposed');
    return _ReplayFrame(frame.image.clone(), frame.duration);
  }

  Future<ui.FrameInfo> _decodeOnce() async {
    final frame = await _delegate.getNextFrame();
    if (_disposed) {
      frame.image.dispose();
      throw StateError('Codec has been disposed');
    }
    _kept = frame.image;
    return frame;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _kept?.dispose();
    _kept = null;
    _delegate.dispose();
  }
}

class _ReplayFrame implements ui.FrameInfo {
  _ReplayFrame(this.image, this.duration);

  @override
  final ui.Image image;

  @override
  final Duration duration;
}

/// Wraps [decode] so the codec it produces is a [ReplaySafeCodec].
ImageDecoderCallback replaySafeDecode(ImageDecoderCallback decode) =>
    (buffer, {getTargetSize}) async =>
        ReplaySafeCodec(await decode(buffer, getTargetSize: getTargetSize));
