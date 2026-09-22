import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/diagnostics/diagnostics_settings.dart';
import 'package:player/core/settings/settings_service.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  final now = DateTime.utc(2026, 9, 22, 12);

  DiagnosticsSettings settingsWith(MockAuthStorage storage, {DateTime? at}) =>
      DiagnosticsSettings(storage: storage, now: () => at ?? now);

  test('defaults to off', () async {
    expect(await settingsWith(MockAuthStorage()).load(), DiagnosticsState.off);
  });

  test('round-trips every choice', () async {
    for (final choice in DiagnosticsChoice.values) {
      final settings = settingsWith(MockAuthStorage());
      final state = DiagnosticsState.chosen(choice, now);

      await settings.save(state);

      expect(await settings.load(), state, reason: choice.name);
    }
  });

  test('a timed choice ends after its window', () {
    expect(DiagnosticsState.chosen(DiagnosticsChoice.logs24h, now).logsUntil,
        now.add(const Duration(hours: 24)));
    expect(DiagnosticsState.chosen(DiagnosticsChoice.logs7d, now).logsUntil,
        now.add(const Duration(days: 7)));
    expect(
        DiagnosticsState.chosen(DiagnosticsChoice.logsForever, now).logsUntil,
        isNull);
  });

  test('an ended timed choice loads as crashes and is stored that way',
      () async {
    final storage = MockAuthStorage();
    await settingsWith(storage)
        .save(DiagnosticsState.chosen(DiagnosticsChoice.logs24h, now));

    final later = settingsWith(storage, at: now.add(const Duration(hours: 25)));

    expect(await later.load(),
        const DiagnosticsState(choice: DiagnosticsChoice.crashes));
    expect(await storage.read(DiagnosticsSettings.choiceKey), 'crashes');
    expect(await storage.read(DiagnosticsSettings.untilKey), isNull);
  });

  test('logs until turned off never ends', () async {
    final storage = MockAuthStorage();
    await settingsWith(storage)
        .save(DiagnosticsState.chosen(DiagnosticsChoice.logsForever, now));

    final muchLater =
        settingsWith(storage, at: now.add(const Duration(days: 400)));

    expect((await muchLater.load()).choice, DiagnosticsChoice.logsForever);
  });

  test('logsActiveAt follows the choice and its end', () {
    final timed = DiagnosticsState.chosen(DiagnosticsChoice.logs24h, now);
    expect(timed.logsActiveAt(now), isTrue);
    expect(timed.logsActiveAt(now.add(const Duration(hours: 25))), isFalse);
    expect(DiagnosticsState.off.logsActiveAt(now), isFalse);
    expect(
        const DiagnosticsState(choice: DiagnosticsChoice.crashes)
            .logsActiveAt(now),
        isFalse);
  });

  test('crashes are shared by every choice but off', () {
    for (final choice in DiagnosticsChoice.values) {
      expect(DiagnosticsState(choice: choice).crashesEnabled,
          choice != DiagnosticsChoice.off);
    }
  });

  test('migrates an opted-in crash consent to crashes', () async {
    final storage = MockAuthStorage();
    await storage.write(DiagnosticsSettings.legacyCrashKey, 'true');

    expect(await settingsWith(storage).load(),
        const DiagnosticsState(choice: DiagnosticsChoice.crashes));
    expect(await storage.read(DiagnosticsSettings.legacyCrashKey), isNull);
    expect(await storage.read(DiagnosticsSettings.choiceKey), 'crashes');
  });

  test('migrates an opted-out crash consent to off', () async {
    final storage = MockAuthStorage();
    await storage.write(DiagnosticsSettings.legacyCrashKey, 'false');

    expect(await settingsWith(storage).load(), DiagnosticsState.off);
    expect(await storage.read(DiagnosticsSettings.legacyCrashKey), isNull);
  });

  test('deviceId is created once and kept', () async {
    final settings = settingsWith(MockAuthStorage());

    final first = await settings.deviceId();
    final second = await settings.deviceId();

    expect(first, second);
    expect(first, matches(RegExp(r'^[0-9a-f-]{36}$')));
  });

  test('signing out does not clear the diagnostics choice', () async {
    final storage = MockAuthStorage();
    await settingsWith(storage)
        .save(DiagnosticsState.chosen(DiagnosticsChoice.logsForever, now));

    await SettingsService(storage: storage).clearSettings();

    expect((await settingsWith(storage).load()).choice,
        DiagnosticsChoice.logsForever);
  });
}
