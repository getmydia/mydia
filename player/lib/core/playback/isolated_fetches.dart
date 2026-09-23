import 'package:flutter/foundation.dart' show debugPrint;

/// Runs independent fetches at once, each failing on its own.
///
/// The player screen's pre-play queries were already failure-isolated (one
/// failing never sank another) but still awaited one after another, so their
/// round trips added up before the first frame.
Future<void> runIsolated(
  Map<String, Future<void> Function()> tasks, {
  void Function(String line) log = _debugPrint,
}) async {
  await Future.wait(tasks.entries.map((task) async {
    try {
      await task.value();
    } catch (e) {
      log('[runIsolated] ${task.key} failed: $e');
    }
  }));
}

void _debugPrint(String line) => debugPrint(line);
