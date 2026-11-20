/// What the macOS mpv surface sets on a player when it attaches.
library;

import 'video_scaling.dart';

/// The options `MpvSurfacePlugin.attach` writes after `wid` and before
/// `vid=auto`, in order.
///
/// The output first: gpu-next over Vulkan (MoltenVK) on the host view,
/// `target-colorspace-hint` off until the source turns out to be HDR (see
/// [colorspaceHintFor]), and VideoToolbox decode. Then mpv's own defaults
/// for the quality options
/// media_kit lowers on every player for its texture path; its
/// `hdr-compute-peak=no` in particular degrades HDR tone mapping. `dither`
/// names an algorithm, and mpv's default is `fruit`: it has no `auto`, and
/// mpv rejects one.
///
/// `wid` and `vid` are absent on purpose: the plugin writes the host view's
/// pointer first and `vid=auto` last, since mpv creates the output when
/// `vid` turns on and reads everything else at that moment.
List<(String, String)> surfaceAttachOptions() => const [
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
    ];

/// mpv's `target-colorspace-hint` for a source whose `video-params/gamma`
/// is [gamma], or null while it is unknown.
///
/// On only for PQ and HLG, which need it to reach the screen's EDR range.
/// For SDR it stays off: with it on, libplacebo picks MoltenVK's BT.709
/// swapchain, which tags the layer `kCGColorSpaceITUR_709`, and ColorSync
/// decodes that with a pure 2.4 power. SDR then shows 11% darker at mid
/// grey and 60% darker in the shadows than on the sRGB swapchain mpv uses
/// with the hint off, where it renders SDR as-is like the texture path.
String? colorspaceHintFor(String? gamma) => switch (gamma) {
      null || '' || 'auto' => null,
      'pq' || 'hlg' => 'yes',
      _ => 'no',
    };

/// mpv's `panscan` for [scaling]: the surface's equivalent of the `BoxFit`
/// the texture path puts on `Video`.
String panscanFor(VideoScaling scaling) => switch (scaling) {
      VideoScaling.fit => '0.0',
      VideoScaling.fill => '1.0',
    };
