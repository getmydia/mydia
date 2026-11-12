/// Whether the app is in the foreground, for long work a suspension cuts
/// off.
///
/// iOS freezes a backgrounded app within seconds. A request in flight then
/// gets no answer, and its timeout, overdue, fires the moment the app comes
/// back, before the resume is even reported. So work that fails with the
/// network can ask whether the app left in the meantime ([departures]
/// changed) and, if it did, wait for [whenForeground] and try again rather
/// than give up.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AppForeground {
  var _foreground = true;
  var _departures = 0;
  Completer<void>? _back;

  bool get foreground => _foreground;

  /// How many times the app has left the foreground. Compare a reading
  /// taken before some work with one after it to learn whether the app
  /// left during it.
  int get departures => _departures;

  /// Completes once the app is in the foreground: now, if it is.
  Future<void> whenForeground() =>
      _foreground ? Future<void>.value() : (_back ??= Completer<void>()).future;

  /// Fed every lifecycle change by the app. `inactive` alone (Control
  /// Center, a system sheet over the app) is not leaving: the app keeps
  /// running.
  void onLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        _back?.complete();
        _back = null;
      case AppLifecycleState.hidden ||
            AppLifecycleState.paused ||
            AppLifecycleState.detached:
        if (_foreground) {
          _foreground = false;
          _departures++;
        }
      case AppLifecycleState.inactive:
        break;
    }
  }
}

/// The app's [AppForeground], fed by `MyApp.didChangeAppLifecycleState`.
final appForegroundProvider = Provider<AppForeground>((ref) => AppForeground());
