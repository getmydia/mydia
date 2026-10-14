import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/theme/colors.dart';
import '../../core/theme/native_glass_support.dart';

/// Apple's native Liquid Glass behind [child], where the OS has it.
///
/// On iOS 26+ and macOS 26+ this stacks a non-interactive platform view
/// (`NativeGlassPlugin` in each Runner target) under [child]. The native
/// view samples the real composited pixels behind it, which a Flutter
/// `BackdropFilter` approximation cannot do.
///
/// Everywhere else it returns `fallback(child)`, which must be exactly the
/// widget the call site built before native glass existed, so non-Apple
/// platforms, older OS versions and every existing test are unchanged.
///
/// The corner radius is applied natively. Do not wrap this in a
/// `ClipRRect`: a clip on a platform view costs an extra mutator pass and
/// gains nothing.
class NativeGlass extends StatelessWidget {
  const NativeGlass({
    super.key,
    required this.cornerRadius,
    this.tint,
    this.border,
    required this.fallback,
    required this.child,
  });

  /// Platform view type and method channel name.
  static const String viewType = 'mydia/native-glass';

  /// Tint used when a call site passes none. Native glass has no
  /// counterpart to `DepthTokens.glassLegibilityFloor`; this value is tuned
  /// by eye on bright artwork at the device gate.
  static Color get defaultTint => AppColors.surface.withValues(alpha: 0.35);

  /// Whether [build] will render native glass right now.
  static bool get available =>
      NativeGlassSupport.supported &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  final double cornerRadius;
  final Color? tint;

  /// Painted over the native glass only. The fallback draws its own.
  final BoxBorder? border;

  final Widget Function(Widget child) fallback;
  final Widget child;

  Map<String, Object?> get _creationParams => {
        'cornerRadius': cornerRadius,
        'tint': (tint ?? defaultTint).toARGB32(),
        'style': 'regular',
      };

  @override
  Widget build(BuildContext context) {
    if (!available) return fallback(child);

    final Widget glass = defaultTargetPlatform == TargetPlatform.iOS
        ? UiKitView(
            viewType: viewType,
            creationParams: _creationParams,
            creationParamsCodec: const StandardMessageCodec(),
          )
        : AppKitView(
            viewType: viewType,
            creationParams: _creationParams,
            creationParamsCodec: const StandardMessageCodec(),
          );

    final rim = border;
    return Stack(
      children: [
        Positioned.fill(child: IgnorePointer(child: glass)),
        if (rim != null)
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: rim,
                  borderRadius: cornerRadius > 0
                      ? BorderRadius.circular(cornerRadius)
                      : null,
                ),
              ),
            ),
          ),
        child,
      ],
    );
  }
}
