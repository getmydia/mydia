import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A navigator observer that mirrors its navigator's route stack and tells
/// its listeners, after the frame, when it changes.
///
/// After the frame because navigator callbacks can arrive during build, where
/// a listener's `setState` is not allowed.
abstract class _RouteStackObserver extends NavigatorObserver
    with ChangeNotifier {
  final List<Route<dynamic>> _stack = [];
  bool _disposed = false;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final at = oldRoute == null ? -1 : _stack.indexOf(oldRoute);
    if (at >= 0 && newRoute != null) {
      _stack[at] = newRoute;
    } else if (newRoute != null) {
      _stack.add(newRoute);
    }
    _changed();
  }

  void _changed() {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) notifyListeners();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Tracks the root navigator's route stack so the shell can tell a PAGE
/// pushed over it (the immersive player, any go_router page) from a popup
/// (a dialog, a modal bottom sheet).
///
/// `ModalRoute.isCurrent` cannot: it is false for both. The native tab bar
/// must hide for both (it must not sit over a Flutter sheet), but the
/// floating Flutter cast pill may only come back for a page, because a popup
/// is the native accessory's own cast sheet and the pill would paint over it.
class PageCoverObserver extends _RouteStackObserver {
  /// Whether a [PageRoute] sits above [shell] in the stack. Popup routes
  /// (`PopupRoute`: dialogs, modal bottom sheets) never count.
  bool isCovered(Route<dynamic>? shell) => coveredByPage(shell, _stack);

  /// The decision, pure for tests: any [PageRoute] after [shell] in [stack].
  /// A shell that is not in the stack (or null) is not covered.
  static bool coveredByPage(
    Route<dynamic>? shell,
    List<Route<dynamic>> stack,
  ) {
    if (shell == null) return false;
    final at = stack.indexOf(shell);
    if (at < 0) return false;
    return stack.skip(at + 1).any((route) => route is PageRoute);
  }
}

/// Tracks the ShellRoute's own navigator, to see a popup on it.
///
/// `showModalBottomSheet` defaults to `useRootNavigator: false` (and
/// `showDialog` does when asked), so called from a content screen they land
/// on the shell navigator. That leaves the shell's root route current, so `ModalRoute.isCurrent`
/// misses them, yet the native tab bar is drawn above the whole Flutter view
/// and would cover the sheet's controls. [hasPopup] is the missing signal.
class ShellPopupObserver extends _RouteStackObserver {
  /// Whether any [PopupRoute] is in the shell navigator's stack.
  bool get hasPopup => hasPopupRoute(_stack);

  /// The decision, pure for tests.
  static bool hasPopupRoute(List<Route<dynamic>> stack) =>
      stack.any((route) => route is PopupRoute);
}

/// The observer the root `GoRouter` is built with and `AppShell` reads.
final pageCoverObserverProvider = Provider<PageCoverObserver>((ref) {
  final observer = PageCoverObserver();
  ref.onDispose(observer.dispose);
  return observer;
});

/// The observer the `ShellRoute` is built with and `AppShell` reads.
final shellPopupObserverProvider = Provider<ShellPopupObserver>((ref) {
  final observer = ShellPopupObserver();
  ref.onDispose(observer.dispose);
  return observer;
});
