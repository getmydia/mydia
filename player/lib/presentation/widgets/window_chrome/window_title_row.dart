import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/layout/window_chrome_inset.dart';
import '../../../core/window/title_bar_double_click.dart';
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
    @visibleForTesting this.onBandPointerDown,
  });

  final Widget? leading;
  final Widget? title;
  final List<Widget> actions;
  final bool showCast;

  /// Injected by tests. Defaults to the real window.
  final WindowController? controller;

  /// Overrides the band's default pointer-down reporting on macOS.
  ///
  /// Exposed only so `window_title_row_test.dart` can substitute a call
  /// counter for the real native channel call `_onBandPointerDown` resolves
  /// to. Production code always gets that computed default; nothing in the
  /// app passes this.
  @visibleForTesting
  final VoidCallback? onBandPointerDown;

  static const Key castKey = Key('window-title-row-cast');

  /// The band's pointer-down reporter: [onBandPointerDown] if a test
  /// supplied one, otherwise the platform default.
  ///
  /// AppKit already zooms the window on every double-click that lands in
  /// the title bar band, including one that hits a Flutter control drawn
  /// there (back, cast), so `MainFlutterWindow` on macOS routes those
  /// clicks to Flutter alone instead of letting AppKit act on them too (see
  /// `title_bar_double_click.dart`). Flutter has to run the user's System
  /// Settings double-click action itself in exchange, but AppKit's
  /// `NSEvent.clickCount` -- not Flutter's gesture arena -- is the only
  /// thing allowed to decide when two clicks are a double-click, since it is
  /// timed against the user's own System Settings interval rather than
  /// Flutter's fixed `kDoubleTapTimeout`/`kDoubleTapSlop`. So on macOS the
  /// band reports every pointer-down instead of waiting on its own
  /// double-tap gesture, and only when the down reaches this band, i.e. only
  /// on empty band space -- the `Stack` hit-test stops at the cast button,
  /// so the band's `Listener` underneath it never sees a down on the button,
  /// keeping both a drag and this off it too. Every other platform keeps
  /// `WindowDragBand`'s own maximize toggle by passing null through.
  VoidCallback? _onBandPointerDown() =>
      onBandPointerDown ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS
          ? reportMacTitleBarPointerDown
          : null);

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

  /// Inside the band, icon buttons drop to 32px so they clear its edges: the
  /// macOS band is AppKit's fixed 40px title bar, centred on the traffic
  /// lights, and a full-size 40px button fills it top to bottom. Compact
  /// density takes 8px off, and `shrinkWrap` keeps a mobile-sized tap target
  /// from growing it back. The app theme's own style still applies to
  /// everything compact leaves unset.
  static Widget _compactIconButtons(BuildContext context, Widget child) {
    final compact = IconButton.styleFrom(
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: compact.merge(Theme.of(context).iconButtonTheme.style),
      ),
      child: child,
    );
  }

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
                        onPointerDown: _onBandPointerDown(),
                      ),
                    ),
                    Positioned.fill(
                      child: _compactIconButtons(context, row),
                    ),
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
