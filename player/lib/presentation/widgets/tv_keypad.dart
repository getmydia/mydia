import 'package:flutter/material.dart';
import '../../core/theme/colors.dart';
import 'focus_highlight.dart';

class TvKeypad extends StatelessWidget {
  final ValueChanged<String> onCharacterPressed;
  final VoidCallback onDeletePressed;
  final VoidCallback onClearPressed;
  final bool enabled;

  /// The 31 ambiguous-free characters matching Mydia backend claim code alphabet:
  /// Letters (23): A-Z omitting I, L, O
  /// Digits (8): 2-9 omitting 0, 1
  static const List<String> validCharacters = [
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'J',
    'K',
    'M',
    'N',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
  ];

  const TvKeypad({
    super.key,
    required this.onCharacterPressed,
    required this.onDeletePressed,
    required this.onClearPressed,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Rows 1-4: 7 characters each
          for (int row = 0; row < 4; row++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (int col = 0; col < 7; col++)
                    _buildKey(
                      char: validCharacters[row * 7 + col],
                      autofocus: row == 0 && col == 0,
                    ),
                ],
              ),
            ),
          // Row 5: 3 characters ('7', '8', '9') + Delete (span 2) + Clear (span 2)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildKey(char: '7'),
              _buildKey(char: '8'),
              _buildKey(char: '9'),
              _buildActionButton(
                keyName: 'delete',
                label: '⌫ Delete',
                icon: Icons.backspace_outlined,
                flex: 2,
                onPressed: enabled ? onDeletePressed : null,
              ),
              _buildActionButton(
                keyName: 'clear',
                label: 'Clear',
                icon: Icons.refresh_rounded,
                flex: 2,
                onPressed: enabled ? onClearPressed : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKey({required String char, bool autofocus = false}) {
    return Expanded(
      flex: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: FocusHighlight(
          autofocus: autofocus,
          onActivate: enabled ? () => onCharacterPressed(char) : null,
          borderRadius: BorderRadius.circular(8),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: enabled ? () => onCharacterPressed(char) : null,
            child: Container(
              key: ValueKey('tv-key-$char'),
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppColors.border.withValues(alpha: 0.15),
                ),
              ),
              child: Text(
                char,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color:
                      enabled ? AppColors.textPrimary : AppColors.textDisabled,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required String keyName,
    required String label,
    required IconData icon,
    required int flex,
    required VoidCallback? onPressed,
  }) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: FocusHighlight(
          onActivate: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: Container(
              key: ValueKey('tv-key-$keyName'),
              height: 48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surfaceVariant.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: AppColors.border.withValues(alpha: 0.15),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: enabled
                        ? AppColors.textSecondary
                        : AppColors.textDisabled,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: enabled
                          ? AppColors.textPrimary
                          : AppColors.textDisabled,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
