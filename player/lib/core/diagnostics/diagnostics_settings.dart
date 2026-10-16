/// What this device shares with the Mydia developers: crash reports, logs,
/// both or neither.
///
/// Two device-level switches stored through [AuthStorage], so they survive
/// sign-out. `DiagnosticsController` (`diagnostics_provider.dart`) is their
/// only writer.
library;

import 'package:uuid/uuid.dart';

import '../auth/auth_storage.dart';

class DiagnosticsState {
  const DiagnosticsState({required this.crashes, required this.logs});

  static const off = DiagnosticsState(crashes: false, logs: false);

  /// Whether crash reports are sent.
  final bool crashes;

  /// Whether logs are uploaded continuously.
  final bool logs;

  DiagnosticsState copyWith({bool? crashes, bool? logs}) => DiagnosticsState(
        crashes: crashes ?? this.crashes,
        logs: logs ?? this.logs,
      );

  @override
  bool operator ==(Object other) =>
      other is DiagnosticsState &&
      other.crashes == crashes &&
      other.logs == logs;

  @override
  int get hashCode => Object.hash(crashes, logs);

  @override
  String toString() => 'DiagnosticsState(crashes: $crashes, logs: $logs)';
}

class DiagnosticsSettings {
  DiagnosticsSettings({AuthStorage? storage})
      : _storage = storage ?? getAuthStorage();

  static const crashesKey = 'diagnostics.crashes';
  static const logsKey = 'diagnostics.logs';
  static const deviceIdKey = 'diagnostics.device_id';

  /// The five-way choice these switches replaced, and its timed end. Read
  /// once, then deleted.
  static const legacyChoiceKey = 'diagnostics.choice';
  static const legacyUntilKey = 'diagnostics.logs_until';

  /// The crash reporting toggle that choice replaced. Read once, then deleted.
  static const legacyCrashKey = 'crash_reporting_enabled';

  final AuthStorage _storage;

  Future<DiagnosticsState> load() async {
    final crashes = await _storage.read(crashesKey);
    final logs = await _storage.read(logsKey);
    if (crashes == null && logs == null) return _migrate();
    return DiagnosticsState(crashes: crashes == 'true', logs: logs == 'true');
  }

  Future<void> save(DiagnosticsState state) async {
    await _storage.write(crashesKey, '${state.crashes}');
    await _storage.write(logsKey, '${state.logs}');
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
    final choice = await _storage.read(legacyChoiceKey);
    if (choice != null) {
      final state = _fromLegacyChoice(choice);
      await save(state);
      await _storage.delete(legacyChoiceKey);
      await _storage.delete(legacyUntilKey);
      return state;
    }

    final legacy = await _storage.read(legacyCrashKey);
    if (legacy == null) return DiagnosticsState.off;
    final state = DiagnosticsState(crashes: legacy == 'true', logs: false);
    await save(state);
    await _storage.delete(legacyCrashKey);
    return state;
  }

  /// A timed log window becomes logs off: the user agreed to a bounded
  /// window, and an open-ended upload would share more than they chose.
  static DiagnosticsState _fromLegacyChoice(String choice) => switch (choice) {
        'crashes' ||
        'logs_24h' ||
        'logs_7d' =>
          const DiagnosticsState(crashes: true, logs: false),
        'logs_forever' => const DiagnosticsState(crashes: true, logs: true),
        _ => DiagnosticsState.off,
      };
}
