/// What this device shares with the Mydia developers: nothing, crash reports,
/// or crash reports and logs for a while.
///
/// One device-level choice replacing the old crash reporting toggle, stored
/// through [AuthStorage] like that toggle was, so it survives sign-out.
/// `DiagnosticsController` (`diagnostics_provider.dart`) is its only writer.
library;

import 'package:uuid/uuid.dart';

import '../auth/auth_storage.dart';

enum DiagnosticsChoice {
  off('off', 'Off'),
  crashes('crashes', 'Crashes only'),
  logs24h('logs_24h', 'Crashes and logs for 24 hours'),
  logs7d('logs_7d', 'Crashes and logs for 7 days'),
  logsForever('logs_forever', 'Crashes and logs until I turn it off');

  const DiagnosticsChoice(this.wireName, this.label);

  final String wireName;
  final String label;

  /// For widget keys: `diagnostics-level-<keySuffix>`.
  String get keySuffix => wireName.replaceAll('_', '-');

  bool get sharesCrashes => this != off;

  bool get sharesLogs =>
      this == logs24h || this == logs7d || this == logsForever;

  /// How long a timed choice lasts; null for the others.
  Duration? get window => switch (this) {
        logs24h => const Duration(hours: 24),
        logs7d => const Duration(days: 7),
        _ => null,
      };

  static DiagnosticsChoice? fromWire(String? value) {
    for (final choice in values) {
      if (choice.wireName == value) return choice;
    }
    return null;
  }
}

class DiagnosticsState {
  const DiagnosticsState({required this.choice, this.logsUntil});

  static const off = DiagnosticsState(choice: DiagnosticsChoice.off);

  /// [choice] made at [now], with its end when it is timed.
  factory DiagnosticsState.chosen(DiagnosticsChoice choice, DateTime now) {
    final window = choice.window;
    return DiagnosticsState(
      choice: choice,
      logsUntil: window == null ? null : now.toUtc().add(window),
    );
  }

  final DiagnosticsChoice choice;

  /// When a timed choice ends. Null for every other choice.
  final DateTime? logsUntil;

  bool get crashesEnabled => choice.sharesCrashes;

  bool logsActiveAt(DateTime now) {
    final until = logsUntil;
    return choice.sharesLogs && (until == null || now.isBefore(until));
  }

  @override
  bool operator ==(Object other) =>
      other is DiagnosticsState &&
      other.choice == choice &&
      other.logsUntil == logsUntil;

  @override
  int get hashCode => Object.hash(choice, logsUntil);

  @override
  String toString() => 'DiagnosticsState($choice, until: $logsUntil)';
}

class DiagnosticsSettings {
  DiagnosticsSettings({AuthStorage? storage, DateTime Function()? now})
      : _storage = storage ?? getAuthStorage(),
        _now = now ?? DateTime.now;

  static const choiceKey = 'diagnostics.choice';
  static const untilKey = 'diagnostics.logs_until';
  static const deviceIdKey = 'diagnostics.device_id';

  /// The crash reporting toggle this setting replaced. Read once, then deleted.
  static const legacyCrashKey = 'crash_reporting_enabled';

  final AuthStorage _storage;
  final DateTime Function() _now;

  Future<DiagnosticsState> load() async {
    final choice = DiagnosticsChoice.fromWire(await _storage.read(choiceKey));
    if (choice == null) return _migrate();

    if (choice.window == null) return DiagnosticsState(choice: choice);

    final untilMs = int.tryParse(await _storage.read(untilKey) ?? '');
    final until = untilMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(untilMs, isUtc: true);
    if (until == null || !_now().isBefore(until)) {
      const ended = DiagnosticsState(choice: DiagnosticsChoice.crashes);
      await save(ended);
      return ended;
    }
    return DiagnosticsState(choice: choice, logsUntil: until);
  }

  Future<void> save(DiagnosticsState state) async {
    await _storage.write(choiceKey, state.choice.wireName);
    final until = state.logsUntil;
    if (until == null) {
      await _storage.delete(untilKey);
    } else {
      await _storage.write(untilKey, '${until.millisecondsSinceEpoch}');
    }
  }

  /// A random ID for log uploads, created on first use. Deliberately not the
  /// auth `device_id`, so uploaded logs cannot be tied to a server account.
  Future<String> deviceId() async {
    final existing = await _storage.read(deviceIdKey);
    if (existing != null) return existing;
    final id = const Uuid().v4();
    await _storage.write(deviceIdKey, id);
    return id;
  }

  Future<DiagnosticsState> _migrate() async {
    final legacy = await _storage.read(legacyCrashKey);
    final state = legacy == 'true'
        ? const DiagnosticsState(choice: DiagnosticsChoice.crashes)
        : DiagnosticsState.off;
    if (legacy != null) {
      await save(state);
      await _storage.delete(legacyCrashKey);
    }
    return state;
  }
}
