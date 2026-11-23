import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/palette.dart';
import '../../../widgets/focus_highlight.dart';

enum _RowKind { navigation, toggle, action, select }

/// One row inside a [SettingsCard].
///
/// Four named constructors rather than a pile of optional flags, so a call
/// site reads as its intent: navigate somewhere, flip something, pick a value, or do
/// something.
class SettingsRow extends StatelessWidget {
  final _RowKind _kind;

  final String title;
  final String? subtitle;

  /// The select button's text on `.select`. Null draws no button.
  final String? valueLabel;

  /// Colour of a small status dot drawn before the subtitle. `.navigation`
  /// only, and only meaningful alongside a subtitle. Null draws no dot, which
  /// is every row that is not reporting live state.
  final Color? subtitleDotColor;

  /// Arbitrary trailing widget. `.action` only.
  final Widget? trailing;

  final VoidCallback? onTap;
  final bool danger;
  final bool toggleValue;
  final ValueChanged<bool>? onChanged;

  /// Takes focus when first built. `.navigation` only, for a screen whose
  /// first row is where a remote should land.
  final bool autofocus;

  /// A row that opens another screen.
  ///
  /// A null [onTap] dims the row.
  const SettingsRow.navigation({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleDotColor,
    required this.onTap,
    this.autofocus = false,
  }) : _kind = _RowKind.navigation,
       valueLabel = null,
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
    required this.title,
    this.subtitle,
    required bool value,
    required this.onChanged,
  }) : _kind = _RowKind.toggle,
       valueLabel = null,
       trailing = null,
       onTap = null,
       danger = false,
       toggleValue = value,
       subtitleDotColor = null,
       autofocus = false;

  /// A row that does something in place, or that simply states a fact.
  ///
  /// Unlike `.navigation`, a null [onTap] here does *not* dim: diagnostics is
  /// built almost entirely from informational action rows, and dimming those
  /// would make a healthy screen look broken.
  const SettingsRow.action({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
  }) : _kind = _RowKind.action,
       valueLabel = null,
       toggleValue = false,
       onChanged = null,
       subtitleDotColor = null,
       autofocus = false;

  /// A row that picks one value from a list, shown as a button at the trailing
  /// edge. Activating the row (not just the button) opens the picker.
  ///
  /// A null [onTap] dims the row, like `.navigation`.
  const SettingsRow.select({
    super.key,
    required this.title,
    this.subtitle,
    required String? value,
    required this.onTap,
  }) : _kind = _RowKind.select,
       valueLabel = value,
       trailing = null,
       danger = false,
       toggleValue = false,
       onChanged = null,
       subtitleDotColor = null,
       autofocus = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final isToggle = _kind == _RowKind.toggle;
    final dimmed =
        ((_kind == _RowKind.navigation || _kind == _RowKind.select) &&
            onTap == null) ||
        (isToggle && onChanged == null);
    final subtitleText = subtitle;

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52 - 24),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: danger ? scheme.error : palette.textPrimary,
                    ),
                  ),
                  if (subtitleText != null) ...[
                    const SizedBox(height: 2),
                    _Subtitle(text: subtitleText, dotColor: subtitleDotColor),
                  ],
                ],
              ),
            ),
            if (_kind == _RowKind.select && valueLabel != null) ...[
              const SizedBox(width: 12),
              // The row is the focus target; the button is only a look.
              ExcludeFocus(child: _SelectValue(valueLabel!)),
            ],
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
            if (isToggle) ...[
              const SizedBox(width: 12),
              // The row is the focus target, so the switch stays out of the
              // traversal order. It remains clickable by pointer: ExcludeFocus
              // only removes focusability, not hit testing.
              ExcludeFocus(
                // A real 40x24 layout box: FittedBox shrinks the themed switch
                // into it, so the row keeps its 52px height.
                child: SizedBox(
                  key: const Key('settings-row-switch-box'),
                  width: 40,
                  height: 24,
                  child: FittedBox(
                    child: Switch.adaptive(
                      value: toggleValue,
                      onChanged: onChanged,
                    ),
                  ),
                ),
              ),
            ],
            if (_kind == _RowKind.navigation) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 20, color: palette.textDisabled),
            ],
          ],
        ),
      ),
    );

    final toggleCallback = onChanged;

    return Opacity(
      opacity: dimmed ? 0.45 : 1.0,
      // FocusHighlight draws the ring for keyboard and D-pad traversal and
      // activates on Enter, Space or select. A null callback makes it
      // unfocusable, so dimmed and purely informational rows are skipped.
      //
      // A toggle row's pointer affordance is the switch, not the row. Wrapping
      // it in an InkWell would make the whole row look tappable by mouse while
      // doing nothing. Under a remote the whole row is one stop and activating
      // it flips the switch.
      //
      // MergeSemantics folds the title, subtitle and switch into one node so a
      // screen reader names the setting when it announces the switch.
      child: isToggle
          ? FocusHighlight(
              onActivate: toggleCallback == null
                  ? null
                  : () => toggleCallback(!toggleValue),
              child: MergeSemantics(child: content),
            )
          : FocusHighlight(
              onActivate: onTap,
              autofocus: autofocus,
              // The InkWell keeps the pointer ripple. Focus belongs to
              // FocusHighlight, so the InkWell must not also be a stop.
              child: InkWell(
                canRequestFocus: false,
                onTap: onTap,
                child: content,
              ),
            ),
    );
  }
}

class _SelectValue extends StatelessWidget {
  const _SelectValue(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      key: const Key('settings-row-select-value'),
      // A minimum, not a fixed height: at large text scales the value grows
      // instead of clipping.
      constraints: const BoxConstraints(minHeight: 30, maxWidth: 200),
      padding: const EdgeInsets.only(left: 10, right: 6),
      decoration: BoxDecoration(
        color: palette.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: palette.textPrimary),
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.expand_more, size: 16, color: palette.textSecondary),
        ],
      ),
    );
  }
}

class _Subtitle extends StatelessWidget {
  const _Subtitle({required this.text, this.dotColor});

  final String text;
  final Color? dotColor;

  static TextStyle _style(MydiaPalette p) =>
      TextStyle(fontSize: 12.5, height: 1.4, color: p.textSecondary);

  @override
  Widget build(BuildContext context) {
    final style = _style(context.palette);
    final color = dotColor;
    if (color == null) return Text(text, style: style);

    return Row(
      children: [
        Container(
          key: const Key('settings-row-status-dot'),
          width: 8,
          height: 8,
          decoration: BoxDecoration(shape: BoxShape.circle, color: color),
        ),
        const SizedBox(width: 7),
        Flexible(child: Text(text, style: style)),
      ],
    );
  }
}
