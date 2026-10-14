import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/material_color_utilities.dart';
import 'package:player/core/theme/ambient_tint/tint_extraction.dart';

List<int> _flat(int argb, [int count = 4096]) => List<int>.filled(count, argb);

Future<MemoryImage> _png(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 64, 36),
    Paint()..color = color,
  );
  final image = await recorder.endRecording().toImage(64, 36);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  return MemoryImage(bytes!.buffer.asUint8List());
}

void main() {
  test('a saturated flat colour yields a seed of that hue', () async {
    final seed = await tintFromPixels(_flat(0xFF2F4A9F));
    expect(seed, isNotNull);
    final hue = Hct.fromInt(seed!.toARGB32()).hue;
    final expected = Hct.fromInt(0xFF2F4A9F).hue;
    expect((hue - expected).abs(), lessThan(10));
  });

  test('greyscale art yields null', () async {
    expect(await tintFromPixels(_flat(0xFF808080)), isNull);
  });

  test('no pixels yields null', () async {
    expect(await tintFromPixels(const []), isNull);
  });

  testWidgets('extractTint decodes a provider', (tester) async {
    final provider = await tester.runAsync(() => _png(const Color(0xFF9F2F2F)));
    final seed = await tester.runAsync(() => extractTint(provider!));
    expect(seed, isNotNull);
  });

  testWidgets('a decode failure yields null', (tester) async {
    final seed = await tester.runAsync(
      () => extractTint(MemoryImage(Uint8List.fromList([1, 2, 3]))),
    );
    expect(seed, isNull);
  });
}
