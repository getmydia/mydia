import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Tracks the root navigator's route stack so the shell can tell a PAGE
/// pushed over it (the immersive player, any go_router page) from a popup
/// (a dialog, a modal bottom sheet).
///
/// `ModalRoute.isCurrent` cannot: it is false for both. The native tab bar
/// must hide for both (it must not sit over a Flutter sheet), but the
/// floating Flutter cast pill may only come back for a page, because a popup
/// is the native accessory's own cast sheet and the pill would paint over it.
///
/// Notifies after the frame, because navigator callbacks can arrive during
/// build, where a listener's `setState` is not allowed.
class PageCoverObserver extends NavigatorObserver with ChangeNotifier {
  final List<Route<dynamic>> _stack = [];
  bool _disposed = false;

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

/// The observer the root `GoRouter` is built with and `AppShell` reads.
final pageCoverObserverProvider = Provider<PageCoverObserver>((ref) {
  final observer = PageCoverObserver();
  ref.onDispose(observer.dispose);
  return observer;
});
