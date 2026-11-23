import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/theme/liquid_glass/glass_style.dart';
import '../../../core/theme/palette.dart';
import '../../../core/ui/reduced_motion.dart';
import 'press_scale.dart';

/// The player's on/off switch.
///
/// Frosted draws a compact 40x24 track with a 20 dp white thumb that slides
/// without resizing (Material's 52x32 track cannot be themed down to that).
/// Liquid renders the stock [Switch] unchanged. Constructor shape mirrors
/// [Switch] for the parameters in use, so call sites only change the class.
class AppSwitch extends StatelessWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.focusNode,
    this.autofocus = false,
    this.activeThumbColor,
    this.adaptive = false,
  });

  final bool value;

  /// Null disables the switch: not focusable, dimmed, ignores input.
  final ValueChanged<bool>? onChanged;
  final FocusNode? focusNode;
  final bool autofocus;

  /// Liquid only; forwarded to [Switch.activeThumbColor].
  final Color? activeThumbColor;

  /// Liquid only; renders [Switch.adaptive] so iOS and macOS get the
  /// Cupertino switch. Frosted draws its own track either way.
  final bool adaptive;

  static const trackKey = ValueKey('app-switch-track');
  static const thumbKey = ValueKey('app-switch-thumb');

  static const double trackWidth = 40;
  static const double trackHeight = 24;
  static const double thumbSize = 20;
  static const double _hitHeight = 48;
  static const double disabledOpacity = 0.38;
  static const _slide = Duration(milliseconds: 160);

  @override
  Widget build(BuildContext context) {
    if (GlassStyle.of(context)) {
      return adaptive
          ? Switch.adaptive(
              value: value,
              onChanged: onChanged,
              focusNode: focusNode,
              autofocus: autofocus,
              activeThumbColor: activeThumbColor,
            )
          : Switch(
              value: value,
              onChanged: onChanged,
              focusNode: focusNode,
              autofocus: autofocus,
              activeThumbColor: activeThumbColor,
            );
    }
    return _FrostedSwitch(
      value: value,
      onChanged: onChanged,
      focusNode: focusNode,
      autofocus: autofocus,
    );
  }
}

class _FrostedSwitch extends StatefulWidget {
  const _FrostedSwitch({
    required this.value,
    required this.onChanged,
    required this.focusNode,
    required this.autofocus,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<_FrostedSwitch> createState() => _FrostedSwitchState();
}

class _FrostedSwitchState extends State<_FrostedSwitch> {
  bool _focusHighlight = false;

  bool get _enabled => widget.onChanged != null;

  void _toggle() => widget.onChanged?.call(!widget.value);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final duration = ReducedMotion.duration(context, AppSwitch._slide);

    final track = AnimatedContainer(
      key: AppSwitch.trackKey,
      duration: duration,
      curve: Curves.easeOut,
      width: AppSwitch.trackWidth,
      height: AppSwitch.trackHeight,
      padding: const EdgeInsets.all(
        (AppSwitch.trackHeight - AppSwitch.thumbSize) / 2,
      ),
      decoration: BoxDecoration(
        color: widget.value ? palette.primary : palette.border,
        borderRadius: BorderRadius.circular(AppSwitch.trackHeight / 2),
      ),
      // Painted over the track, outside layout, so focus never changes the
      // padding or the thumb geometry.
      foregroundDecoration: _focusHighlight
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(AppSwitch.trackHeight / 2),
              border: Border.all(color: Colors.white, width: 1.5),
            )
          : null,
      child: AnimatedAlign(
        duration: duration,
        curve: Curves.easeOut,
        alignment: widget.value
            ? AlignmentDirectional.centerEnd
            : AlignmentDirectional.centerStart,
        child: const DecoratedBox(
          key: AppSwitch.thumbKey,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          child: SizedBox(
            width: AppSwitch.thumbSize,
            height: AppSwitch.thumbSize,
          ),
        ),
      ),
    );

    return Semantics(
      toggled: widget.value,
      enabled: _enabled,
      onTap: _enabled ? _toggle : null,
      child: ExcludeSemantics(
        child: Opacity(
          opacity: _enabled ? 1.0 : AppSwitch.disabledOpacity,
          child: PressScale(
            enabled: _enabled,
            child: FocusableActionDetector(
              enabled: _enabled,
              focusNode: widget.focusNode,
              autofocus: widget.autofocus,
              onShowFocusHighlight: (v) => setState(() => _focusHighlight = v),
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
                    _toggle();
                    return null;
                  },
                ),
              },
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _enabled ? _toggle : null,
                child: SizedBox(
                  width: AppSwitch.trackWidth,
                  height: AppSwitch._hitHeight,
                  child: Center(child: track),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A list row with an [AppSwitch] at its end: the replacement for
/// [SwitchListTile].
///
/// The row is the single focus stop and tapping anywhere on it toggles; the
/// switch itself is excluded from focus, as in [SwitchListTile]. Liquid
/// renders the stock [SwitchListTile] unchanged.
class AppSwitchTile extends StatelessWidget {
  const AppSwitchTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.dense,
    this.contentPadding,
  });

  final bool value;

  /// Null disables the row and its switch.
  final ValueChanged<bool>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final bool? dense;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) {
    final changed = onChanged;
    if (GlassStyle.of(context)) {
      return SwitchListTile(
        value: value,
        onChanged: changed,
        title: title,
        subtitle: subtitle,
        dense: dense,
        contentPadding: contentPadding,
      );
    }
    return MergeSemantics(
      child: ListTile(
        title: title,
        subtitle: subtitle,
        dense: dense,
        contentPadding: contentPadding,
        enabled: changed != null,
        onTap: changed == null ? null : () => changed(!value),
        // As in SwitchListTile: a toggle, not a button.
        internalAddSemanticForOnTap: false,
        trailing: ExcludeFocus(
          child: AppSwitch(value: value, onChanged: changed),
        ),
      ),
    );
  }
}
