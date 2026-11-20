import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/surface_attach_options.dart';
import 'package:player/core/player/video_scaling.dart';

void main() {
  test('attach options follow wid in the documented order, without vid', () {
    expect(surfaceAttachOptions(), const [
      ('vo', 'gpu-next'),
      ('gpu-api', 'vulkan'),
      ('gpu-context', 'macvk'),
      ('target-colorspace-hint', 'no'),
      ('hwdec', 'videotoolbox'),
      ('scale', 'lanczos'),
      ('dscale', 'hermite'),
      ('dither', 'fruit'),
      ('correct-downscaling', 'yes'),
      ('linear-downscaling', 'yes'),
      ('sigmoid-upscaling', 'yes'),
      ('hdr-compute-peak', 'auto'),
    ]);
  });

  test('neither wid nor vid is in the list: the plugin owns both', () {
    final names = surfaceAttachOptions().map((o) => o.$1);
    expect(names, isNot(contains('wid')));
    expect(names, isNot(contains('vid')));
  });

  test('the colorspace hint is on for PQ and HLG only', () {
    expect(colorspaceHintFor('pq'), 'yes');
    expect(colorspaceHintFor('hlg'), 'yes');
    for (final sdr in ['bt.1886', 'srgb', 'gamma2.2', 'linear']) {
      expect(colorspaceHintFor(sdr), 'no', reason: sdr);
    }
    for (final unknown in [null, '', 'auto']) {
      expect(colorspaceHintFor(unknown), isNull, reason: '$unknown');
    }
  });

  test('panscan is 0 for fit and 1 for fill', () {
    expect(panscanFor(VideoScaling.fit), '0.0');
    expect(panscanFor(VideoScaling.fill), '1.0');
  });
}
