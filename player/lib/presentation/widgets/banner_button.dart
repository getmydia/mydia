import 'package:flutter/material.dart';

/// A compact action styled to sit inside a shell banner.
///
/// One control for OfflineBanner, CompatibilityBanner and UpdateBanner, which
/// carried three copies of the same padding, radius, alpha and text style
/// between them. [isLoading] generalises the spinner OfflineBanner's retry
/// needed; the others pass the default.
class BannerButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onPressed;
  final bool isLoading;

  const BannerButton({
    super.key,
    required this.label,
    required this.color,
    required this.onPressed,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: isLoading ? null : onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: color.withValues(alpha: 0.2),
        foregroundColor: color,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      child: isLoading
          ? SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          : Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
    );
  }
}
