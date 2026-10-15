import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

import 'ambient_tint_colors.dart';

/// Physical width the tint decodes artwork at. About 4,000 pixels for a
/// 16:9 backdrop, which is plenty for one dominant colour.
const int tintDecodeWidth = 64;

/// Score's fallback when nothing is suitable. Fully transparent, so it can
/// never be a real pixel from [_argbPixels].
const int _noSeed = 0x00000000;

/// The dominant usable colour in [argbPixels], or null when the art is
/// effectively grey. Pure and isolate-safe.
Future<Color?> tintFromPixels(List<int> argbPixels) async {
  if (argbPixels.isEmpty) return null;
  final result = await QuantizerCelebi().quantize(argbPixels, 16);
  final ranked = Score.score(
    result.colorToCount,
    desired: 1,
    fallbackColorARGB: _noSeed,
  );
  final top = ranked.first;
  if (top == _noSeed) return null;
  if (Hct.fromInt(top).chroma < AmbientTintColors.minSeedChroma) return null;
  return Color(top);
}

/// Decodes [provider] (already sized, see `tintDecodeWidth`) and returns its
/// seed colour, or null when the decode fails, takes longer than
/// [timeout], or the art is grey.
Future<Color?> extractTint(
  ImageProvider provider, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  try {
    final image = await _decode(provider, timeout);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      final pixels = _argbPixels(data);
      final argb = await compute(_seedArgb, pixels);
      return argb == null ? null : Color(argb);
    } finally {
      image.dispose();
    }
  } catch (e) {
    debugPrint('[AmbientTint] extraction failed: $e');
    return null;
  }
}

Future<int?> _seedArgb(List<int> pixels) async =>
    (await tintFromPixels(pixels))?.toARGB32();

/// Opaque pixels only: transparent letterboxing must not vote.
List<int> _argbPixels(ByteData rgba) {
  final out = <int>[];
  for (var i = 0; i + 3 < rgba.lengthInBytes; i += 4) {
    final a = rgba.getUint8(i + 3);
    if (a < 128) continue;
    out.add(
      (0xFF << 24) |
          (rgba.getUint8(i) << 16) |
          (rgba.getUint8(i + 1) << 8) |
          rgba.getUint8(i + 2),
    );
  }
  return out;
}

Future<ui.Image> _decode(ImageProvider provider, Duration timeout) {
  final completer = Completer<ui.Image>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      stream.removeListener(listener);
      completer.complete(info.image.clone());
      info.dispose();
    },
    onError: (error, stack) {
      stream.removeListener(listener);
      completer.completeError(error, stack);
    },
  );
  stream.addListener(listener);
  // A stalled load must not keep the listener, and so the image stream,
  // alive after the caller has given up on it.
  return completer.future.timeout(timeout, onTimeout: () {
    stream.removeListener(listener);
    throw TimeoutException('artwork decode', timeout);
  });
}
