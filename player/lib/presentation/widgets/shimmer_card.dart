import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';
import '../../core/theme/palette.dart';
import '../../core/theme/app_theme.dart';

class ShimmerCard extends StatelessWidget {
  final double width;
  final double height;

  const ShimmerCard({
    super.key,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Shimmer.fromColors(
      baseColor: palette.shimmerBase,
      highlightColor: palette.shimmerHighlight,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: palette.shimmerBase,
          borderRadius: BorderRadius.circular(AppTheme.radiusCard),
        ),
      ),
    );
  }
}
