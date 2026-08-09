import 'package:flutter/material.dart';

import '../../../../core/theme/colors.dart';

enum _RowKind { navigation, toggle, action }

/// One row inside a [SettingsCard].
///
/// Three named constructors rather than a pile of optional flags, so a call
/// site reads as its intent: navigate somewhere, flip something, or do
/// something.
class SettingsRow extends StatelessWidget {
  final _RowKind _kind;
  final IconData icon;
  final String title;
  final String? subtitle;

  /// Muted trailing text. `.navigation` only.
  final String? valueLabel;

  /// Arbitrary trailing widget. `.action` only.
  final Widget? trailing;

  final VoidCallback? onTap;
  final bool danger;
  final bool toggleValue;
  final ValueChanged<bool>? onChanged;

  /// A row that opens another screen.
  ///
  /// A null [onTap] dims the row. That is how the quality row reads while
  /// preferences are unavailable.
  const SettingsRow.navigation({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    String? value,
    required this.onTap,
  })  : _kind = _RowKind.navigation,
        valueLabel = value,
        trailing = null,
        danger = false,
        toggleValue = false,
        onChanged = null;

  /// A row that flips a boolean.
  ///
  /// A null [onChanged] disables the switch and dims the row, which is how the
  /// degraded Playback section is expressed when preferences fail to load.
  const SettingsRow.toggle({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required bool value,
    required this.onChanged,
  })  : _kind = _RowKind.toggle,
        valueLabel = null,
        trailing = null,
        onTap = null,
        danger = false,
        toggleValue = value;

  /// A row that does something in place, or that simply states a fact.
  ///
  /// Unlike `.navigation`, a null [onTap] here does *not* dim: diagnostics is
  /// built almost entirely from informational action rows, and dimming those
  /// would make a healthy screen look broken.
  const SettingsRow.action({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
  })  : _kind = _RowKind.action,
        valueLabel = null,
        toggleValue = false,
        onChanged = null;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isToggle = _kind == _RowKind.toggle;
    final dimmed = (_kind == _RowKind.navigation && onTap == null) ||
        (isToggle && onChanged == null);

    final content = Padding(
      padding:
          EdgeInsets.symmetric(horizontal: 16, vertical: isToggle ? 8 : 13),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 26),
        child: Row(
          children: [
            _IconTile(icon: icon, danger: danger),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.1,
                      color: danger ? scheme.error : AppColors.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (valueLabel != null) ...[
              const SizedBox(width: 12),
              _ValueText(valueLabel!),
            ],
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ],
            if (isToggle) ...[
              const SizedBox(width: 12),
              Switch(value: toggleValue, onChanged: onChanged),
            ],
            if (_kind == _RowKind.navigation) ...[
              const SizedBox(width: 4),
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: AppColors.textDisabled,
              ),
            ],
          ],
        ),
      ),
    );

    return Opacity(
      opacity: dimmed ? 0.45 : 1.0,
      // A toggle row's affordance is the switch, not the row. Wrapping it in an
      // InkWell would make the whole row look tappable while doing nothing.
      child: isToggle ? content : InkWell(onTap: onTap, child: content),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon, required this.danger});

  final IconData icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: danger
            ? scheme.error.withValues(alpha: 0.1)
            : Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        icon,
        size: 16,
        color: danger ? scheme.error : AppColors.textSecondary,
      ),
    );
  }
}

class _ValueText extends StatelessWidget {
  const _ValueText(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    return Text(
      value,
      style: const TextStyle(fontSize: 13.5, color: AppColors.textSecondary),
    );
  }
}
