import 'package:material_ui/material_ui.dart';

import '../../../../core/theme/palette.dart';
import '../../../widgets/focus_highlight.dart';

/// How a [SettingsChoiceGrid] option arranges its preview and text.
enum SettingsChoiceLayout {
  /// Preview above the label. For theme-like choices.
  stacked,

  /// Preview to the left of the label and description.
  inline,
}

/// One option of a [SettingsChoiceGrid].
class SettingsChoice<T> {
  const SettingsChoice({
    required this.value,
    required this.label,
    this.description,
    required this.preview,
  });

  final T value;
  final String label;
  final String? description;

  /// Fills the preview box; the grid sizes and clips it.
  final Widget preview;
}

/// A radio-style grid of previewable options (themes, materials).
///
/// Each option is its own focus stop, so arrow keys and a D-pad move between
/// them geometrically and Enter selects.
class SettingsChoiceGrid<T> extends StatelessWidget {
  const SettingsChoiceGrid({
    super.key,
    required this.label,
    required this.choices,
    required this.selected,
    required this.onSelected,
    this.columns = 4,
    this.layout = SettingsChoiceLayout.stacked,
  });

  /// Group semantics label.
  final String label;
  final List<SettingsChoice<T>> choices;
  final T selected;
  final ValueChanged<T> onSelected;

  /// Drops to 2 below [_narrowWidth] of available width.
  final int columns;
  final SettingsChoiceLayout layout;

  static const double _gap = 10;
  static const double _narrowWidth = 400;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      container: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final available = constraints.maxWidth;
          final cols = available < _narrowWidth && columns > 2 ? 2 : columns;
          final itemWidth = (available - _gap * (cols - 1)) / cols;
          return Wrap(
            spacing: _gap,
            runSpacing: _gap,
            children: [
              for (var i = 0; i < choices.length; i++)
                SizedBox(
                  width: itemWidth,
                  child: _Option<T>(
                    key: Key('settings-choice-$i'),
                    choice: choices[i],
                    isSelected: choices[i].value == selected,
                    layout: layout,
                    onTap: () => onSelected(choices[i].value),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Option<T> extends StatelessWidget {
  const _Option({
    super.key,
    required this.choice,
    required this.isSelected,
    required this.layout,
    required this.onTap,
  });

  final SettingsChoice<T> choice;
  final bool isSelected;
  final SettingsChoiceLayout layout;
  final VoidCallback onTap;

  static const double _radius = 12;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final radius = BorderRadius.circular(_radius);
    final textStyle = TextStyle(
      fontSize: layout == SettingsChoiceLayout.stacked ? 12.5 : 13.5,
      fontWeight: isSelected || layout == SettingsChoiceLayout.inline
          ? FontWeight.w600
          : FontWeight.w400,
      color: palette.textPrimary,
    );

    final Widget body;
    if (layout == SettingsChoiceLayout.stacked) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 72,
            child: ClipRRect(borderRadius: radius, child: choice.preview),
          ),
          const SizedBox(height: 8),
          Text(
            choice.label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textStyle,
          ),
        ],
      );
    } else {
      final description = choice.description;
      body = Row(
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: choice.preview,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(choice.label, style: textStyle),
                if (description != null)
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 12,
                      color: palette.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }

    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: isSelected,
      label: choice.label,
      hint: choice.description,
      child: FocusHighlight(
        onActivate: onTap,
        borderRadius: radius,
        child: InkWell(
          canRequestFocus: false,
          borderRadius: radius,
          onTap: onTap,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: isSelected ? palette.primary : palette.border,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Padding(
              padding: EdgeInsets.all(
                layout == SettingsChoiceLayout.stacked ? 8 : 12,
              ),
              // The label and hint above name the option; the visible text
              // would only be read twice.
              child: ExcludeSemantics(child: body),
            ),
          ),
        ),
      ),
    );
  }
}
