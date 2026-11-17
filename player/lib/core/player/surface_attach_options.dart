/// What the macOS mpv surface sets on a player when it attaches.
library;

import 'video_scaling.dart';

/// The options `MpvSurfacePlugin.attach` writes after `wid` and before
/// `vid=auto`, in order.
///
/// The output first: gpu-next over Vulkan (MoltenVK) on the host view,
/// `target-colorspace-hint` so the output follows the screen's EDR range,
/// and VideoToolbox decode. Then mpv's own defaults for the quality options
/// media_kit lowers on every player for its texture path; its
/// `hdr-compute-peak=no` in particular degrades HDR tone mapping.
///
/// `wid` and `vid` are absent on purpose: the plugin writes the host view's
/// pointer first and `vid=auto` last, since mpv creates the output when
/// `vid` turns on and reads everything else at that moment.
List<(String, String)> surfaceAttachOptions() => const [
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
    ];

/// mpv's `panscan` for [scaling]: the surface's equivalent of the `BoxFit`
/// the texture path puts on `Video`.
String panscanFor(VideoScaling scaling) => switch (scaling) {
      VideoScaling.fit => '0.0',
      VideoScaling.fill => '1.0',
    };
