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
