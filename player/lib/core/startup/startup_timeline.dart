import 'package:flutter/foundation.dart' show debugPrint;

/// Named millisecond marks since construction, logged as one line.
///
/// Exists because nothing measured cold start or Play-to-first-frame, so no
/// change to either could show what it saved. Marks record the first time
/// they are hit and ignore repeats, so a mark placed on a path that can run
/// twice still reports the first occurrence.
class StartupTimeline {
  StartupTimeline(this.label, {int Function()? elapsedMs})
      : _elapsedMs = elapsedMs ?? _stopwatchClock();

  static int Function() _stopwatchClock() {
    final sw = Stopwatch()..start();
    return () => sw.elapsedMilliseconds;
  }

  /// The app's cold-start timeline, started when this library is first
  /// touched, which is the first statement of `main()`.
  static final StartupTimeline app = StartupTimeline('startup');

  final String label;
  final int Function() _elapsedMs;
  final Map<String, int> _marks = <String, int>{};
  bool _logged = false;

  void mark(String name) => _marks.putIfAbsent(name, _elapsedMs);

  Map<String, int> get marks => Map.unmodifiable(_marks);

  String summary() =>
      '$label: ${_marks.entries.map((e) => '${e.key}=${e.value}').join(' ')}';

  void logOnce([void Function(String line) log = _debugPrint]) {
    if (_logged) return;
    _logged = true;
    log(summary());
  }
}

void _debugPrint(String line) => debugPrint(line);
