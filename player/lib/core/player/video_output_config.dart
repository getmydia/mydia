import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:media_kit_video/media_kit_video.dart'
    show VideoControllerConfiguration;

/// mpv's hardware decoder for Android that keeps the frame on the GPU.
///
/// The name is mpv's, not media_kit's: media_kit passes `hwdec` through to
/// libmpv untouched.
const androidZeroCopyHwdec = 'mediacodec';

/// How the decoded frame should reach mpv's renderer on this platform.
///
/// media_kit's Android default is `hwdec=auto-safe`, which resolves to
/// `mediacodec-copy`: the hardware codec decodes, then every frame is read
/// back into CPU memory before mpv uploads it as a texture. That readback
/// comes off a GPU/codec buffer rather than ordinary RAM, so it costs far more
/// than the ~75 MB/s that 1080p24 NV12 suggests. On a Chromecast with Google
/// TV (Amlogic, 4x Cortex-A55) it saturates the single `CodecLooper` thread,
/// measured at 91% of one core with three cores sitting idle, and playback
/// settles at 0.78x realtime, which is the stutter. Nothing upstream was
/// short: the server had hundreds of segments already encoded and answered
/// every request in under 160ms.
///
/// [androidZeroCopyHwdec] is the same hardware decoder with the readback
/// removed. The frame stays on the GPU and reaches mpv as a SurfaceTexture.
/// mpv documents it as requiring `--vo=gpu --gpu-context=android`, and
/// media_kit already sets `gpu-context: android` and `opengl-es: yes` on
/// Android, so `vo` stays `gpu` and mpv keeps compositing.
///
/// mpv keeping the compositing is the whole reason this is not
/// `vo=mediacodec_embed`. Embedding hands frames straight to a SurfaceView and
/// mpv never draws, which silently removes subtitles and the OSD, and this
/// player renders both through mpv. Embedding also cannot accept
/// software-decoded frames, so a hwdec failure has nowhere to fall back to.
/// With `vo=gpu` a failure just drops to software decode and still renders.
///
/// Android only, for two reasons. `hwdec` values are platform specific, and
/// mpv deliberately leaves `mediacodec` out of `auto-safe` because it converts
/// to RGB and its handling of unusual colorspaces is unverified. Every other
/// platform keeps media_kit's own default.
VideoControllerConfiguration videoControllerConfigurationFor(
  TargetPlatform platform, {
  required bool isWeb,
}) {
  if (!isWeb && platform == TargetPlatform.android) {
    return const VideoControllerConfiguration(hwdec: androidZeroCopyHwdec);
  }
  return const VideoControllerConfiguration();
}
