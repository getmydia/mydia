import 'package:flutter/material.dart';

import '../../../core/theme/colors.dart';
import '../../../core/theme/depth_tokens.dart';
import '../glass_surface.dart';
import 'toast_models.dart';

/// The glass pill a toast renders as.
///
/// Pure presentation. Timing, hover, swipe and placement live in
/// `ToastLayer`. Every kind shares the same neutral glass; only the leading
/// glyph carries severity, the way the palette keeps chrome neutral and lets
/// poster art carry the colour.
class ToastPill extends StatelessWidget {
  const ToastPill({super.key, required this.entry, this.onAction});

  final ToastEntry entry;

  /// Called when the action button is pressed. The button renders whenever
  /// [ToastEntry.action] is set.
  final VoidCallback? onAction;

  /// Browse-chrome density: at or above
  /// [DepthTokens.glassLegibilityFloor], so text stays legible over bright
  /// artwork behind the blur.
  static final Color fill =
      DepthTokens.surfaceHigh.withValues(alpha: DepthTokens.chromeFillOpacity);

  static const BorderRadius _radius =
      BorderRadius.all(Radius.circular(ToastMetrics.radius));

  @override
  Widget build(BuildContext context) {
    final leading = _leading();
    final action = entry.action;
    return Semantics(
      container: true,
      liveRegion: true,
      child: ConstrainedBox(
        key: const Key('toast-pill'),
        constraints: const BoxConstraints(maxWidth: ToastMetrics.maxWidth),
        child: DecoratedBox(
          // The shadow lives on an outer box because GlassSurface clips its
          // own blurred fill, the same split `BottomNav` uses.
          decoration: const BoxDecoration(
            borderRadius: _radius,
            boxShadow: DepthTokens.chrome,
          ),
          child: GlassSurface(
            blurSigma: DepthTokens.blurChrome,
            fillColor: fill,
            borderRadius: _radius,
            border: Border.all(
              color: DepthTokens.rimColor,
              width: DepthTokens.rimWidth,
            ),
            // The layer sits above the Navigator, outside any Scaffold, so
            // the pill brings its own Material for the text style and the
            // action button's ink.
            child: Material(
              type: MaterialType.transparency,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (leading != null) ...[
                      leading,
                      const SizedBox(width: 10),
                    ],
                    Flexible(
                      child: Text(
                        entry.message,
                        maxLines: ToastMetrics.maxLines,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    if (action != null) ...[
                      const SizedBox(width: 12),
                      TextButton(
                        key: const Key('toast-action'),
                        onPressed: onAction,
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          minimumSize: const Size(0, 32),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(action.label),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget? _leading() {
    switch (entry.kind) {
      case ToastKind.info:
        final icon = entry.icon;
        if (icon == null) return null;
        return Icon(icon, size: 18, color: AppColors.textSecondary);
      case ToastKind.success:
        return const Icon(Icons.check_circle_rounded,
            size: 18, color: AppColors.success);
      case ToastKind.error:
        return const Icon(Icons.error_rounded,
            size: 18, color: AppColors.error);
      case ToastKind.progress:
        return const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.primary,
          ),
        );
    }
  }
}
