import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/depth_tokens.dart';
import '../../../core/theme/palette.dart';
import '../../../core/ui/reduced_motion.dart';
import '../glass_surface.dart';
import '../toast/toast_obstruction.dart';
import 'back_to_mydia_button.dart';
import 'rail_scope.dart';
import 'sidebar_content.dart';

/// Floating navigation rail: collapsed to icons at rest, expanding over the
/// content (never reflowing it) on hover, focus, pin or its expand button.
/// The button is what a touch screen has, since touch never hovers.
class FloatingRail extends ConsumerStatefulWidget {
  const FloatingRail({
    super.key,
    required this.location,
    required this.onNavigate,
    required this.isOffline,
    this.showBackToMydia = false,
    this.selectedRowFocusNode,
    this.onExitRequested,
    this.topInset = 0,
  });

  final String location;
  final ValueChanged<String> onNavigate;
  final bool isOffline;
  final bool showBackToMydia;
  final FocusNode? selectedRowFocusNode;

  /// Back or Escape inside the rail: the shell returns focus to content.
  final VoidCallback? onExitRequested;

  /// Extra top clearance: the macOS traffic lights, or the status bar on a
  /// device with no window chrome.
  final double topInset;

  static const Duration hoverDelay = Duration(milliseconds: 200);

  /// The dim behind the expanded rail, shared with the floating phone drawer
  /// so the two overlays match.
  static Color scrimColor(BuildContext context) => Colors.black
      .withValues(alpha: MediaQuery.highContrastOf(context) ? 0.7 : 0.55);

  @override
  ConsumerState<FloatingRail> createState() => _FloatingRailState();
}

class _FloatingRailState extends ConsumerState<FloatingRail> {
  bool _hovered = false;
  bool _focused = false;

  /// Opened with the expand button; stays open until dismissed.
  bool _opened = false;
  Timer? _hoverTimer;

  /// The footer's edit button. Leaving edit mode disposes the edit bar's
  /// Done button, which would otherwise take focus with it and collapse the
  /// rail under a keyboard or remote user.
  final FocusNode _editFocus = FocusNode(debugLabel: 'rail-edit');

  bool get _pinned => ref.read(railPinnedProvider);
  bool _expandedFor(bool pinned) => pinned || _hovered || _focused || _opened;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _editFocus.dispose();
    super.dispose();
  }

  void _setExpanded(void Function() change) {
    setState(change);
    _exitEditWhenCollapsed(_expandedFor(_pinned));
  }

  /// Edit mode is an expanded-only action, so collapsing ends it.
  void _exitEditWhenCollapsed(bool expanded) {
    if (!expanded) ref.read(sidebarEditModeProvider.notifier).exit();
  }

  void _collapse() {
    _hoverTimer?.cancel();
    _setExpanded(() {
      _hovered = false;
      _focused = false;
      _opened = false;
    });
  }

  /// The expand button. Collapsing a pinned rail unpins it, or the button
  /// would do nothing.
  void _toggle(bool expanded) {
    if (!expanded) return _setExpanded(() => _opened = true);
    if (_pinned) ref.read(railPinnedProvider.notifier).toggle();
    _collapse();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      _collapse();
      widget.onExitRequested?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _navigate(String route) {
    widget.onNavigate(route);
    if (!_pinned) _collapse();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(sidebarEditModeProvider, (prev, next) {
      // Runs before the rebuild, while focus is still on the control that
      // ended editing, so moving it here keeps the user inside the rail.
      if (prev == true && !next && _focused) _editFocus.requestFocus();
    });
    ref.listen<bool>(railPinnedProvider, (prev, next) {
      if (prev == null || prev == next) return;
      _exitEditWhenCollapsed(_expandedFor(next));
    });
    final pinned = ref.watch(railPinnedProvider);
    final expanded = _expandedFor(pinned);
    final showScrim = expanded && !pinned;
    final highContrast = MediaQuery.highContrastOf(context);
    final duration = context.reducedMotionDuration(DepthTokens.motionMedium);
    const inset = Breakpoints.railInset;
    final safe = MediaQuery.paddingOf(context);

    return Stack(
      children: [
        Positioned.fill(
          // Always mounted so it can fade; inert while hidden.
          child: IgnorePointer(
            key: const Key('rail-scrim-guard'),
            ignoring: !showScrim,
            child: AnimatedOpacity(
              key: const Key('rail-scrim-fade'),
              opacity: showScrim ? 1 : 0,
              duration: duration,
              curve: DepthTokens.curveStandard,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _collapse,
                child: ColoredBox(
                  // Findable only while the scrim is meant to be showing.
                  key: showScrim ? const Key('rail-scrim') : null,
                  color: FloatingRail.scrimColor(context),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          // Clear of a display cutout or gesture area (landscape phones).
          left: inset + safe.left,
          top: inset + widget.topInset,
          bottom: inset + safe.bottom,
          child: ToastObstruction(
            edge: ToastEdge.left,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onKey,
              onFocusChange: (hasFocus) =>
                  _setExpanded(() => _focused = hasFocus),
              child: MouseRegion(
                onEnter: (_) {
                  _hoverTimer?.cancel();
                  _hoverTimer = Timer(FloatingRail.hoverDelay, () {
                    if (mounted) _setExpanded(() => _hovered = true);
                  });
                },
                onExit: (_) {
                  _hoverTimer?.cancel();
                  _setExpanded(() => _hovered = false);
                },
                child: AnimatedContainer(
                  key: const Key('floating-rail'),
                  duration: duration,
                  curve: DepthTokens.curveStandard,
                  width: expanded
                      ? Breakpoints.railExpandedWidth
                      : Breakpoints.railCollapsedWidth,
                  child: GlassSurface.chrome(
                    opacity: highContrast ? 0.96 : (expanded ? 0.92 : 0.8),
                    borderRadius: const BorderRadius.all(
                      Radius.circular(AppTheme.radiusRail),
                    ),
                    border: Border.all(
                      color: DepthTokens.rimColor,
                      width: DepthTokens.rimWidth,
                    ),
                    shadows: DepthTokens.chrome,
                    child: ClipRect(
                      // Always laid out at the expanded width: the collapsed
                      // rail clips it, so nothing re-lays-out or moves.
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: Breakpoints.railExpandedWidth,
                        maxWidth: Breakpoints.railExpandedWidth,
                        child: SidebarContent(
                          rail: true,
                          railLabelsVisible: expanded,
                          location: widget.location,
                          onNavigate: _navigate,
                          isOffline: widget.isOffline,
                          selectedRowFocusNode: widget.selectedRowFocusNode,
                          backToMydiaWidget: widget.showBackToMydia
                              ? const BackToMydiaButton()
                              : null,
                          railFooter: _RailFooter(
                            expanded: expanded,
                            pinned: pinned,
                            editFocus: _editFocus,
                            onToggle: () => _toggle(expanded),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The rail's expand button, then pin and edit-sidebar. The expand button
/// sits in the rows' icon column in both states; pin and edit are invisible,
/// inert and out of focus traversal while the rail is collapsed.
class _RailFooter extends ConsumerWidget {
  const _RailFooter({
    required this.expanded,
    required this.pinned,
    required this.editFocus,
    required this.onToggle,
  });

  final bool expanded;
  final bool pinned;
  final FocusNode editFocus;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final editing = ref.watch(sidebarEditModeProvider);
    return SizedBox(
      height: RailScope.rowHeight,
      child: Row(
        children: [
          // Pointer-only while collapsed: focus expands the rail on its own.
          ExcludeFocus(
            excluding: !expanded,
            // Pinned to the rows' 48px icon box: desktop's compact density
            // would otherwise shrink the button to 40px, 4px left of the
            // row icons.
            child: SizedBox.square(
              dimension: RailScope.iconBox,
              child: IconButton(
                key: const Key('rail-toggle'),
                tooltip: expanded ? 'Collapse sidebar' : 'Expand sidebar',
                onPressed: onToggle,
                color: palette.textSecondary,
                visualDensity: VisualDensity.standard,
                icon: Icon(
                  expanded
                      ? Icons.keyboard_double_arrow_left_rounded
                      : Icons.keyboard_double_arrow_right_rounded,
                ),
              ),
            ),
          ),
          ExcludeFocus(
            excluding: !expanded,
            child: ExcludeSemantics(
              excluding: !expanded,
              child: IgnorePointer(
                ignoring: !expanded,
                child: RailLabel(
                  visible: expanded,
                  child: Row(
                    children: [
                      IconButton(
                        key: const Key('rail-pin'),
                        tooltip: pinned ? 'Unpin sidebar' : 'Pin sidebar',
                        onPressed: () =>
                            ref.read(railPinnedProvider.notifier).toggle(),
                        icon: Icon(
                          pinned
                              ? Icons.push_pin_rounded
                              : Icons.push_pin_outlined,
                        ),
                      ),
                      IconButton(
                        key: const Key('rail-edit'),
                        focusNode: editFocus,
                        tooltip: 'Edit sidebar',
                        onPressed: () =>
                            ref.read(sidebarEditModeProvider.notifier).toggle(),
                        icon: Icon(
                          Icons.edit_outlined,
                          color:
                              editing ? palette.primary : palette.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
