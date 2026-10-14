import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/navigation/sidebar_layout_providers.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/depth_tokens.dart';
import '../../../core/ui/reduced_motion.dart';
import '../glass_surface.dart';
import '../toast/toast_obstruction.dart';
import 'back_to_mydia_button.dart';
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
  bool _labels = false;
  Timer? _hoverTimer;
  Timer? _labelTimer;

  bool get _pinned => ref.read(railPinnedProvider);
  bool _expandedFor(bool pinned) => pinned || _hovered || _focused;

  @override
  void dispose() {
    _hoverTimer?.cancel();
    _labelTimer?.cancel();
    super.dispose();
  }

  void _setExpanded(void Function() change) {
    final before = _expandedFor(_pinned);
    setState(change);
    _syncExpansion(before, _expandedFor(_pinned));
  }

  /// Runs the label and edit-mode side of an expansion change. [wasPinned]
  /// marks an unpin: the labels were showing, so they stay when the rail
  /// remains expanded (hover or focus) even though expansion did not change.
  void _syncExpansion(bool before, bool after, {bool wasPinned = false}) {
    if (before == after && !wasPinned) return;
    _labelTimer?.cancel();
    if (!after) {
      setState(() => _labels = false);
      ref.read(sidebarEditModeProvider.notifier).exit();
      return;
    }
    if (wasPinned || context.reduceMotion) {
      setState(() => _labels = true);
    } else {
      _labelTimer = Timer(DepthTokens.motionMedium * 0.6, () {
        if (mounted) setState(() => _labels = true);
      });
    }
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
      _syncExpansion(
        _expandedFor(prev),
        _expandedFor(next),
        wasPinned: prev && !next,
      );
    });
    final pinned = ref.watch(railPinnedProvider);
    final expanded = _expandedFor(pinned);
    final labels = pinned || (expanded && _labels);
    final highContrast = MediaQuery.highContrastOf(context);
    final duration = context.reducedMotionDuration(DepthTokens.motionMedium);
    const inset = Breakpoints.railInset;

    return Stack(
      children: [
        if (expanded && !pinned)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _collapse,
              child: ColoredBox(
                key: const Key('rail-scrim'),
                color:
                    Colors.black.withValues(alpha: highContrast ? 0.7 : 0.55),
              ),
            ),
          ),
        Positioned(
          left: inset,
          top: inset + widget.topInset,
          bottom: inset,
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
                      child: OverflowBox(
                        alignment: Alignment.topLeft,
                        minWidth: 0,
                        maxWidth: labels
                            ? Breakpoints.railExpandedWidth
                            : Breakpoints.railCollapsedWidth,
                        child: Column(
                          children: [
                            Expanded(
                              child: SidebarContent(
                                compact: !labels,
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
                            if (expanded)
                              IconButton(
                                key: const Key('rail-pin'),
                                tooltip:
                                    pinned ? 'Unpin sidebar' : 'Pin sidebar',
                                onPressed: () => ref
                                    .read(railPinnedProvider.notifier)
                                    .toggle(),
                                icon: Icon(
                                  pinned
                                      ? Icons.push_pin_rounded
                                      : Icons.push_pin_outlined,
                                ),
                              ),
                            const SizedBox(height: 8),
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
