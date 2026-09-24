import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/window/window_controller.dart';
import '../../../core/window/window_controller_native.dart';
import '../cast_actions.dart';
import '../cast_button.dart';
import 'window_drag_band.dart';

/// The one header row every screen draws.
///
/// On a windowed desktop it is the title bar: it sits in the band the window
/// controls live in, keeps only the corners they occupy clear
/// ([WindowChromeInsets]), and is a drag handle wherever it is empty. With no
/// desktop chrome (mobile, web, TV, fullscreen) it is an ordinary
/// `kToolbarHeight` row below the status bar.
///
/// The cast button is not a caller action. It is always last, at
/// [endGutter] from the trailing edge, so it lines up on every screen.
class WindowTitleRow extends ConsumerWidget {
  const WindowTitleRow({
    super.key,
    this.leading,
    this.title,
    this.actions = const [],
    this.showCast = true,
    this.controller,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget> actions;
  final bool showCast;

  /// Injected by tests. Defaults to the real window.
  final WindowController? controller;

  static const Key castKey = Key('window-title-row-cast');

  static double heightOf(BuildContext context) {
    final insets = WindowChromeInsets.of(context);
    return insets.isZero ? kToolbarHeight : insets.height;
  }

  /// Space between the last control and the trailing edge (after any
  /// window-control reserve). The desktop value is the browse screens'
  /// existing gutter, so their content column and header edges agree.
  static double endGutter(BuildContext context) =>
      Breakpoints.isDesktop(context)
          ? Breakpoints.getHorizontalPadding(context) - 8
          : 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final insets = WindowChromeInsets.of(context);
    final gutter = endGutter(context);
    final leadingWidget = leading;
    final titleWidget = title;

    final row = Padding(
      padding: EdgeInsetsDirectional.only(
        start: insets.leading + gutter,
        end: insets.trailing + gutter,
      ),
      child: Row(
        children: [
          if (leadingWidget != null) leadingWidget,
          Expanded(
            child: titleWidget == null
                ? const SizedBox.shrink()
                : Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: titleWidget,
                  ),
          ),
          ...actions,
          if (showCast)
            CastButton(
              key: castKey,
              onPressed: () => pickCastDevice(context, ref),
            ),
        ],
      ),
    );

    return WindowChromeInsets.removeBand(
      child: SafeArea(
        bottom: false,
        left: false,
        right: false,
        child: SizedBox(
          height: heightOf(context),
          child: insets.isZero
              ? row
              : Stack(
                  children: [
                    // Behind the row: a click on a control is the control's,
                    // everything else in the band moves the window.
                    Positioned.fill(
                      child: WindowDragBand(
                        controller:
                            controller ?? const WindowManagerController(),
                        height: insets.height,
                      ),
                    ),
                    Positioned.fill(child: row),
                  ],
                ),
        ),
      ),
    );
  }
}

/// [WindowTitleRow] shaped for `Scaffold.appBar`.
///
/// The caller passes [height] from [WindowTitleRow.heightOf] because
/// `preferredSize` has no context. The `Scaffold` must sit under
/// [WindowChromeInsets.removeBand], or it adds the band to the slot height a
/// second time.
class WindowTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const WindowTitleBar({
    super.key,
    required this.height,
    this.leading,
    this.title,
    this.actions = const [],
    this.showCast = true,
    this.decorate,
  });

  final double height;
  final Widget? leading;
  final Widget? title;
  final List<Widget> actions;
  final bool showCast;

  /// Wraps the row in a background (for example `GlassSurface.appBar`).
  final Widget Function(Widget row)? decorate;

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context) {
    final row = WindowTitleRow(
      leading: leading,
      title: title,
      actions: actions,
      showCast: showCast,
    );
    return decorate?.call(row) ?? row;
  }
}
