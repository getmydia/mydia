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

  static const double _padHorizontal = 16;
  static const double _padVertical = 12;

  static const EdgeInsets _padding = EdgeInsets.symmetric(
    horizontal: _padHorizontal,
    vertical: _padVertical,
  );

  /// The action never takes more than half the pill's content width.
  ///
  /// [ToastMetrics.maxWidth] governs the pill, so a long or localised label
  /// must yield to the cap rather than run past it and be silently cut off by
  /// `GlassSurface`'s `ClipRRect`. Wrapping the button in a [Flexible] would
  /// bound it too, but a [Row] splits space by flex factor rather than by
  /// need: two flexible children split the free width evenly, so a short
  /// label would silently shrink the message with it. Bounding the button's
  /// intrinsic width instead leaves the message the whole remainder, so a
  /// short-label pill lays out exactly as an unbounded action would. The row
  /// then fits any parent at least 234 wide (a 194 cap plus the 28 glyph and
  /// 12 gap), which is narrower than any supported window once the layer's
  /// 16px gutters are taken off it.
  static const double _maxActionWidth =
      (ToastMetrics.maxWidth - 2 * _padHorizontal) / 2;

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
                padding: _padding,
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
                      ConstrainedBox(
                        constraints:
                            const BoxConstraints(maxWidth: _maxActionWidth),
                        child: TextButton(
                          key: const Key('toast-action'),
                          onPressed: onAction,
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.primary,
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            action.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
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
