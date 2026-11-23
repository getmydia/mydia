import 'package:material_ui/material_ui.dart';

import '../../../../core/focus/focus_memory.dart';
import '../../../../core/player/input_capabilities.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/theme/palette.dart';
import '../../../widgets/glass_surface.dart';

/// A grouped container for settings rows.
///
/// Uses [GlassSurface.faux] rather than live glass: settings scrolls, and R8 in
/// `depth_tokens.dart` reserves real [BackdropFilter] passes for small fixed
/// chrome. A scrolling surface with live blur pays for a backdrop pass on every
/// frame it moves.
class SettingsCard extends StatelessWidget {
  final List<Widget> children;

  const SettingsCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final radius = BorderRadius.circular(AppTheme.radiusSettingsCard);
    // GlassSurface.faux takes no border colour, only the light rim, so the
    // palette outline is drawn over the content instead.
    return GlassSurface.faux(
      borderRadius: radius,
      fillColor: palette.surfaceVariant.withValues(alpha: 0.55),
      showRim: false,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: palette.border.withValues(alpha: 0.6)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _withDividers(children, palette),
        ),
      ),
    );
  }

  /// Dividers are drawn by the card, not the rows, so a row never has to know
  /// whether it is last.
  static List<Widget> _withDividers(
    List<Widget> children,
    MydiaPalette palette,
  ) {
    if (children.length < 2) return children;

    final result = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        result.add(
          Divider(height: 1, thickness: 1, indent: 16, color: palette.divider),
        );
      }
      result.add(children[i]);
    }
    return result;
  }
}

/// A sentence-case label above a [SettingsCard], and an optional [footer]
/// note under it.
///
/// The strings are rendered as given. Transforming the label to upper case
/// would make screen readers spell or shout it, and would break `find.text`
/// against the label a caller actually passed.
class SettingsSection extends StatelessWidget {
  /// The header above the card. Null when the page already names the section;
  /// focus ids then use an empty label.
  final String? label;
  final List<Widget> children;

  /// A short explanation shown under the card.
  final String? footer;

  const SettingsSection({
    super.key,
    required this.label,
    required this.children,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final order = InputCapabilities.directionalPrimary
        ? SettingsFocusOrder.maybeOf(context)
        : null;
    final rows = order == null
        ? children
        : [
            for (final (i, row) in children.indexed)
              FocusMemoryItem(
                // The label and the row's own key where it has one: a row
                // shown conditionally then does not shift its neighbours'
                // ids. The position stands in only for unkeyed rows.
                id: (label ?? '', row.key ?? i),
                index: order * SettingsFocusOrder.rowsPerSection + i,
                child: row,
              ),
          ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (label case final label?)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 2, 8),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.palette.textPrimary.withValues(alpha: 0.8),
              ),
            ),
          ),
        SettingsCard(children: rows),
        if (footer case final footer?)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 8, 2, 0),
            child: Text(
              footer,
              style: TextStyle(
                fontSize: 12,
                color: context.palette.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}

/// Where the [SettingsSection]s under it sit in the Settings list, for the
/// television's focus memory.
///
/// Settings is one list of sections, each built by its own widget, so a
/// section cannot know on its own how its rows order against the others'.
/// The screen places each section in this with its position, and on a
/// television the section makes each row an item of the list's
/// `FocusMemoryRegion`, indexed by section then row. A section with no
/// order above it (the same sections on a server's own settings screen or
/// in the desktop dialog) is left as it was.
class SettingsFocusOrder extends InheritedWidget {
  const SettingsFocusOrder({
    super.key,
    required this.order,
    required super.child,
  });

  /// Room left for each section's rows in the item indices; a section has
  /// far fewer.
  static const int rowsPerSection = 100;

  final int order;

  static int? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsFocusOrder>()?.order;

  @override
  bool updateShouldNotify(SettingsFocusOrder oldWidget) =>
      order != oldWidget.order;
}
