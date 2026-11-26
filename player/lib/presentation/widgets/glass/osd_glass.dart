import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/liquid_glass/glass_accessibility.dart';
import '../../../core/theme/liquid_glass/glass_style.dart';
import '../../../core/theme/liquid_glass/liquid_glass_support.dart';

/// How the playback OSD draws its glass.
enum OsdGlassMode {
  /// No glass: the OSD renders exactly as it does without Liquid Glass.
  off,

  /// Glass that samples the video behind it through the shader.
  sampled,

  /// Glass that cannot sample the video (macOS surface output, or no shader):
  /// the dry recipe without refraction of the picture.
  dry,
}

/// Decides the [OsdGlassMode]. Glass is only on iOS and macOS, never on the
/// web, only when the app is in the liquid style and never under Reduce
/// Transparency. Only macOS has a video surface the shader cannot sample.
OsdGlassMode resolveOsdGlassMode({
  required bool liquidStyle,
  required bool isWeb,
  required TargetPlatform platform,
  required bool reduceTransparency,
  required bool shaderAvailable,
  required bool surfaceOutput,
}) {
  if (!liquidStyle || isWeb || reduceTransparency) return OsdGlassMode.off;
  return switch (platform) {
    TargetPlatform.iOS =>
      shaderAvailable ? OsdGlassMode.sampled : OsdGlassMode.dry,
    TargetPlatform.macOS =>
      shaderAvailable && !surfaceOutput
          ? OsdGlassMode.sampled
          : OsdGlassMode.dry,
    _ => OsdGlassMode.off,
  };
}

/// Whether the video is drawn to a native surface the shader cannot sample.
final videoSurfaceOutputProvider =
    NotifierProvider<VideoSurfaceOutputNotifier, bool>(
      VideoSurfaceOutputNotifier.new,
    );

class VideoSurfaceOutputNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool active) => state = active;
}

/// Carries the surface-output flag to [OsdGlass.of], which is used outside
/// any `ProviderScope` in many tests.
class OsdGlassScope extends InheritedWidget {
  const OsdGlassScope({
    super.key,
    required this.surfaceOutput,
    required super.child,
  });

  final bool surfaceOutput;

  @override
  bool updateShouldNotify(OsdGlassScope oldWidget) =>
      oldWidget.surfaceOutput != surfaceOutput;
}

/// Mounted once in `MaterialApp.router`'s builder.
class OsdGlassHost extends ConsumerWidget {
  const OsdGlassHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) => OsdGlassScope(
    surfaceOutput: ref.watch(videoSurfaceOutputProvider),
    child: child,
  );
}

abstract final class OsdGlass {
  static OsdGlassMode of(BuildContext context) => resolveOsdGlassMode(
    liquidStyle: GlassStyle.of(context),
    isWeb: kIsWeb,
    platform: defaultTargetPlatform,
    reduceTransparency: GlassAccessibilityScope.of(context).reduceTransparency,
    shaderAvailable: LiquidGlassSupport.available,
    surfaceOutput:
        context
            .dependOnInheritedWidgetOfExactType<OsdGlassScope>()
            ?.surfaceOutput ??
        false,
  );
}
