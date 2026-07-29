import 'package:flutter/widgets.dart' show AppLifecycleState;

/// Decides whether a resume is worth a refetch.
///
/// Pure and clock-injected so the debounce can be tested without a widget
/// tree or a real app lifecycle.
class ResumeGate {
  ResumeGate({this.minimumBackground = defaultMinimumBackground});

  /// Long enough to skip notification shades, control center, permission
  /// dialogs and PiP, short enough that coming back to the app after a real
  /// absence shows current data.
  static const Duration defaultMinimumBackground = Duration(seconds: 30);

  final Duration minimumBackground;

  DateTime? _pausedAt;

  void onPaused(DateTime at) => _pausedAt = at;

  /// Returns whether the app was backgrounded long enough to invalidate.
  /// Consumes the pause, so a repeated resume does not re-trigger.
  bool onResumed(DateTime at) {
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (pausedAt == null) return false;
    return at.difference(pausedAt) >= minimumBackground;
  }
}

/// Maps a raw [AppLifecycleState] transition onto [gate], returning whether
/// the transition warrants a full-library invalidation.
///
/// This is the one place the "notification shades, control center,
/// permission dialogs and PiP all produce `inactive`, not a pause" rule
/// lives. It is a free function — not inline in `_MyAppState`'s
/// `didChangeAppLifecycleState` — precisely so the rule can be pinned by a
/// plain unit test instead of depending on a widget tree or a real
/// OS-driven lifecycle. `_MyAppState` calls this directly.
bool applyAppLifecycleState(
  ResumeGate gate,
  AppLifecycleState state,
  DateTime now,
) {
  switch (state) {
    case AppLifecycleState.paused:
    case AppLifecycleState.hidden:
      gate.onPaused(now);
      return false;
    case AppLifecycleState.resumed:
      return gate.onResumed(now);
    case AppLifecycleState.inactive:
    case AppLifecycleState.detached:
      return false;
  }
}
