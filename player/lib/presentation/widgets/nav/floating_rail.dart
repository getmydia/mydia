import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/colors.dart';
import '../../../core/theme/depth_tokens.dart';
import '../../../core/ui/reduced_motion.dart';
import '../glass_surface.dart';
import '../toast/toast_obstruction.dart';
import 'back_to_mydia_button.dart';
import 'rail_scope.dart';
import 'sidebar_content.dart';

/// Floating navigation rail: collapsed to icons at rest, expanding over the
/// content (never reflowing it) on hover, focus or pin.
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

  /// Extra top clearance for macOS traffic lights.
  final double topInset;

  static const Duration hoverDelay = Duration(milliseconds: 200);

  @override
  ConsumerState<FloatingRail> createState() => _FloatingRailState();
}

class _FloatingRailState extends ConsumerState<FloatingRail> {
  bool _hovered = false;
  bool _focused = false;
  Timer? _hoverTimer;

  bool get _pinned => ref.read(railPinnedProvider);
  bool _expandedFor(bool pinned) => pinned || _hovered || _focused;

  @override
  void dispose() {
    _hoverTimer?.cancel();
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
    });
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
                  color:
                      Colors.black.withValues(alpha: highContrast ? 0.7 : 0.55),
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
                        child: Column(
                          children: [
                            Expanded(
                              child: SidebarContent(
                                rail: true,
                                railLabelsVisible: expanded,
                                location: widget.location,
                                onNavigate: _navigate,
                                isOffline: widget.isOffline,
                                selectedRowFocusNode:
                                    widget.selectedRowFocusNode,
                                backToMydiaWidget: widget.showBackToMydia
                                    ? const BackToMydiaButton()
                                    : null,
                              ),
                            ),
                            _RailFooter(expanded: expanded, pinned: pinned),
                          ],
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

/// Pin and edit-sidebar actions under the rows. It always reserves its height
/// so the rows above never move; while the rail is collapsed the buttons are
/// invisible, inert and out of focus traversal.
class _RailFooter extends ConsumerWidget {
  const _RailFooter({required this.expanded, required this.pinned});

  final bool expanded;
  final bool pinned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final editing = ref.watch(sidebarEditModeProvider);
    return Padding(
      padding: const EdgeInsets.only(left: 12, bottom: 8),
      child: SizedBox(
        height: RailScope.rowHeight,
        child: ExcludeFocus(
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
                      tooltip: 'Edit sidebar',
                      onPressed: () =>
                          ref.read(sidebarEditModeProvider.notifier).toggle(),
                      icon: Icon(
                        Icons.edit_outlined,
                        color: editing
                            ? AppColors.primary
                            : AppColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
