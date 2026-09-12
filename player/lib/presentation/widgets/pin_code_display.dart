import 'package:flutter/material.dart';
import '../../core/theme/colors.dart';

class PinCodeDisplay extends StatelessWidget {
  final String code;
  final int length;
  final bool hasError;
  final bool isLoading;

  const PinCodeDisplay({
    super.key,
    required this.code,
    this.length = 6,
    this.hasError = false,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      key: hasError ? const ValueKey('pin-code-error-state') : null,
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (index) {
        final isFilled = index < code.length;
        final isActive = index == code.length && !hasError && !isLoading;
        final char = isFilled ? code[index] : '';

        Color borderColor;
        if (hasError) {
          borderColor = AppColors.error;
        } else if (isLoading) {
          borderColor = AppColors.primary.withValues(alpha: 0.8);
        } else if (isActive) {
          borderColor = AppColors.primary;
        } else if (isFilled) {
          borderColor = AppColors.border.withValues(alpha: 0.6);
        } else {
          borderColor = AppColors.border.withValues(alpha: 0.25);
        }

        return Container(
          key: ValueKey('pin-slot-$index${isActive ? '-active' : ''}'),
          margin: const EdgeInsets.symmetric(horizontal: 5),
          width: 46,
          height: 56,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: hasError
                ? AppColors.error.withValues(alpha: 0.08)
                : AppColors.surfaceVariant.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: borderColor,
              width: isActive || hasError ? 2.0 : 1.2,
            ),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.25),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Text(
            char,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: hasError ? AppColors.error : AppColors.textPrimary,
              fontFamily: 'monospace',
            ),
          ),
        );
      }),
    );
  }
}
