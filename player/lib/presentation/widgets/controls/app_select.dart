import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/player/input_capabilities.dart';
import '../../../core/theme/palette.dart';
import '../../../core/theme/surface_roles.dart';
import '../focus_emphasis.dart';
import '../media_context_menu.dart' show popupPositionBelow;
import 'press_scale.dart';

/// One choice of an [AppSelect].
@immutable
class AppSelectItem<T> {
  const AppSelectItem({
    required this.value,
    required this.label,
    this.icon,
    this.key,
  });

  final T value;

  /// Shown in the field when this is the value, and as the menu row.
  final String label;

  /// Drawn before [label] in the menu row.
  final IconData? icon;

  /// Put on the menu row, so a test can find and pick it.
  final Key? key;
}

/// The player's select field: a compact field showing the current choice
/// that opens the themed popup menu under it, the current value checked.
///
/// One focus stop. Select, Enter, Space or a tap opens the menu, which
/// handles its own traversal; Back or Escape closes it and focus returns to
/// the field. Sizes to its label; give it a tight width to fill a column.
/// Needs a bounded width, as a long label ellipsizes rather than overflows.
class AppSelect<T> extends StatefulWidget {
  const AppSelect({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.placeholder,
    this.semanticLabel,
    this.enabled = true,
  });

  final List<AppSelectItem<T>> items;

  /// The current choice. One that matches no item shows [placeholder] and
  /// opens the menu with nothing checked.
  final T? value;

  /// Called once with the picked value. Not called when the menu is
  /// dismissed or the current value is picked again.
  final ValueChanged<T> onChanged;

  /// Shown when [value] matches no item.
  final String? placeholder;

  /// Names the field for a screen reader.
  final String? semanticLabel;

  /// When false the field is not focusable, ignores input and dims its label.
  final bool enabled;

  static const fieldKey = ValueKey('app-select-field');
  static const chevronKey = ValueKey('app-select-chevron');
  static const checkKey = ValueKey('app-select-check');

  static const double fieldHeight = 40;
  static const double hitHeight = 48;
  static const double disabledOpacity = 0.38;

  @override
  State<AppSelect<T>> createState() => _AppSelectState<T>();
}

class _AppSelectState<T> extends State<AppSelect<T>> {
  bool _focusHighlight = false;
  bool _open = false;

  int get _selectedIndex =>
      widget.items.indexWhere((item) => item.value == widget.value);

  Future<void> _openMenu(BuildContext anchor) async {
    if (!widget.enabled || _open) return;
    final position = popupPositionBelow(anchor);
    final box = anchor.findRenderObject();
    if (position == null || box is! RenderBox) return;
    final width = box.size.width;
    // The menu shows these rows; resolve the pick against them, not against
    // whatever items the field has by the time it closes.
    final items = List.of(widget.items);
    final selected = _selectedIndex;
    final palette = context.palette;

    _open = true;
    // Indices, not values: a nullable T has null as a real choice, and
    // showMenu also answers null when dismissed.
    final picked = await showMenu<int>(
      context: context,
      position: position,
      constraints: BoxConstraints(
        minWidth: width,
        maxWidth: math.max(width, 280),
      ),
      items: [
        for (var i = 0; i < items.length; i++)
          _AppSelectEntry(
            autofocus: i == (selected < 0 ? 0 : selected),
            child: PopupMenuItem<int>(
              key: items[i].key,
              value: i,
              child: _MenuRow(
                item: items[i],
                checked: i == selected,
                palette: palette,
              ),
            ),
          ),
      ],
    );
    _open = false;
    if (!mounted || picked == null || picked >= items.length) return;
    final value = items[picked].value;
    if (value == widget.value) return;
    widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final roles = context.surfaceRoles;
    final radius = BorderRadius.circular(roles.radiusControl);
    final selected = _selectedIndex;
    final label = selected < 0
        ? (widget.placeholder ?? '')
        : widget.items[selected].label;
    final showPlaceholder = selected < 0;
    final enabled = widget.enabled;
    // On the television tier FocusEmphasis draws the ring; elsewhere the
    // field draws its own, outside layout like AppSwitch's.
    final ownRing = _focusHighlight && !InputCapabilities.directionalPrimary;

    final textColor = !enabled
        ? palette.textPrimary.withValues(alpha: AppSelect.disabledOpacity)
        : showPlaceholder
        ? palette.textSecondary
        : palette.textPrimary;

    return Builder(
      builder: (anchor) {
        final field = Container(
          key: AppSelect.fieldKey,
          height: AppSelect.fieldHeight,
          padding: const EdgeInsets.only(left: 12, right: 8),
          decoration: BoxDecoration(
            color: palette.surfaceLow,
            borderRadius: radius,
            border: Border.all(color: roles.hairlineStrong),
          ),
          foregroundDecoration: ownRing
              ? BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: Colors.white, width: 1.5),
                )
              : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: textColor,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.unfold_more_rounded,
                key: AppSelect.chevronKey,
                size: 18,
                color: enabled
                    ? palette.textSecondary
                    : palette.textSecondary.withValues(
                        alpha: AppSelect.disabledOpacity,
                      ),
              ),
            ],
          ),
        );

        return FocusEmphasis(
          borderRadius: radius,
          child: Semantics(
            button: true,
            enabled: enabled,
            label: widget.semanticLabel,
            value: label,
            onTap: enabled ? () => _openMenu(anchor) : null,
            child: ExcludeSemantics(
              child: FocusableActionDetector(
                enabled: enabled,
                onShowFocusHighlight: (v) =>
                    setState(() => _focusHighlight = v),
                shortcuts: const {
                  SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                  SingleActivator(LogicalKeyboardKey.gameButtonA):
                      ActivateIntent(),
                },
                actions: {
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      _openMenu(anchor);
                      return null;
                    },
                  ),
                },
                // Inside the detector, so PressScale's focus node is below
                // the focused one and only pointer presses scale the field.
                child: PressScale(
                  enabled: enabled,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: enabled ? () => _openMenu(anchor) : null,
                    child: SizedBox(
                      height: AppSelect.hitHeight,
                      child: Center(widthFactor: 1, child: field),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A menu row: optional icon, the label, and a check on the current value.
class _MenuRow<T> extends StatelessWidget {
  const _MenuRow({
    required this.item,
    required this.checked,
    required this.palette,
  });

  final AppSelectItem<T> item;
  final bool checked;
  final MydiaPalette palette;

  @override
  Widget build(BuildContext context) {
    final icon = item.icon;
    return Semantics(
      selected: checked,
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: palette.textSecondary),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Text(
              item.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 18,
            child: checked
                ? Icon(
                    Icons.check_rounded,
                    key: AppSelect.checkKey,
                    size: 18,
                    color: palette.primary,
                  )
                : null,
          ),
        ],
      ),
    );
  }
}

/// Wraps a menu row so the television Back key closes the menu (Escape
/// already does, through the app's DismissIntent), and so the current row
/// takes focus when the menu opens.
class _AppSelectEntry extends PopupMenuEntry<int> {
  const _AppSelectEntry({required this.child, required this.autofocus});

  final PopupMenuItem<int> child;
  final bool autofocus;

  @override
  double get height => child.height;

  @override
  bool represents(int? value) => child.represents(value);

  @override
  State<_AppSelectEntry> createState() => _AppSelectEntryState();
}

class _AppSelectEntryState extends State<_AppSelectEntry> {
  final FocusNode _node = FocusNode(
    canRequestFocus: false,
    skipTraversal: true,
    debugLabel: 'AppSelect entry',
  );

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final node in _node.descendants) {
          if (node.canRequestFocus && !node.skipTraversal) {
            node.requestFocus();
            return;
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.goBack ||
            event.logicalKey == LogicalKeyboardKey.browserBack)) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) =>
      Focus(focusNode: _node, onKeyEvent: _onKey, child: widget.child);
}
