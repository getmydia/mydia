import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/surface_attach_options.dart';
import 'package:player/core/player/video_scaling.dart';

void main() {
  test('attach options follow wid in the documented order, without vid', () {
    expect(surfaceAttachOptions(), const [
      ('vo', 'gpu-next'),
      ('gpu-api', 'vulkan'),
      ('gpu-context', 'macvk'),
      ('target-colorspace-hint', 'yes'),
      ('hwdec', 'videotoolbox'),
      ('scale', 'lanczos'),
      ('dscale', 'hermite'),
      ('dither', 'auto'),
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

  test('panscan is 0 for fit and 1 for fill', () {
    expect(panscanFor(VideoScaling.fit), '0.0');
    expect(panscanFor(VideoScaling.fill), '1.0');
  });
}
