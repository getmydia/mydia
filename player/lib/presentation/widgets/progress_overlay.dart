import 'package:flutter/material.dart';
import '../../core/theme/palette.dart';

class ProgressOverlay extends StatelessWidget {
  final double percentage;
  final double height;

  const ProgressOverlay({
    super.key,
    required this.percentage,
    this.height = 4.0,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: palette.surfaceVariant,
        ),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: percentage / 100.0,
          child: Container(
            decoration: BoxDecoration(
              color: palette.primary,
            ),
          ),
        ),
      ),
    );
  }
}
