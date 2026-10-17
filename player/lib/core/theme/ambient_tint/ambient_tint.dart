import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ui/reduced_motion.dart';
import '../depth_tokens.dart';
import '../palette.dart';
import 'ambient_tint_colors.dart';
import 'ambient_tint_providers.dart';

/// The tint in effect for this subtree. Only widgets that call [of] rebuild
/// when it changes.
class AmbientTint extends InheritedWidget {
  const AmbientTint({super.key, required this.colors, required super.child});

  final AmbientTintColors colors;

  /// The nearest tint, or the palette's neutral outside any scope.
  static AmbientTintColors of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AmbientTint>()?.colors ??
      AmbientTintColors.neutralFor(context.palette);

  @override
  bool updateShouldNotify(AmbientTint oldWidget) => oldWidget.colors != colors;
}

class AmbientTintColorsTween extends Tween<AmbientTintColors> {
  AmbientTintColorsTween({super.begin, super.end});

  @override
  AmbientTintColors lerp(double t) =>
      AmbientTintColors.lerp(begin ?? end!, end!, t);
}

/// Animates to [colors] over the backdrop's crossfade duration and provides
/// the in-between values to [child].
class AmbientTintScope extends StatelessWidget {
  const AmbientTintScope({
    super.key,
    required this.colors,
    required this.child,
  });

  final AmbientTintColors colors;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<AmbientTintColors>(
      tween: AmbientTintColorsTween(end: colors),
      duration: context.reducedMotionDuration(DepthTokens.motionSlow),
      curve: DepthTokens.curveEmphasized,
      builder: (context, value, child) =>
          AmbientTint(colors: value, child: child!),
      child: child,
    );
  }
}

/// The app-wide scope, fed by [ambientTintControllerProvider].
class ShellAmbientTint extends ConsumerWidget {
  const ShellAmbientTint({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    return AmbientTintScope(
      // A preset without the tint never builds the controller, so focus
      // changes extract nothing.
      colors: palette.ambientTint
          ? resolveAmbientTint(
              ref.watch(ambientTintControllerProvider), palette)
          : AmbientTintColors.neutralFor(palette),
      child: child,
    );
  }
}
