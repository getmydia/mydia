import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/diagnostics/diagnostics_settings.dart';
import 'package:player/core/settings/settings_service.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  DiagnosticsSettings settingsWith(MockAuthStorage storage) =>
      DiagnosticsSettings(storage: storage);

  test('defaults to off and writes nothing', () async {
    final storage = MockAuthStorage();

    expect(await settingsWith(storage).load(), DiagnosticsState.off);
    expect(storage.contents, isEmpty);
  });

  test('round-trips every combination', () async {
    for (final crashes in [false, true]) {
      for (final logs in [false, true]) {
        final settings = settingsWith(MockAuthStorage());
        final state = DiagnosticsState(crashes: crashes, logs: logs);

        await settings.save(state);

        expect(await settings.load(), state, reason: '$state');
      }
    }
  });

  group('a save whose second write fails stores neither switch', () {
    test('restores the crash switch it overwrote', () async {
      final storage = MockAuthStorage();
      await settingsWith(storage).save(DiagnosticsState.off);
      storage.failWriteKeys.add(DiagnosticsSettings.logsKey);

      await expectLater(
        settingsWith(storage)
            .save(const DiagnosticsState(crashes: true, logs: true)),
        throwsA(anything),
      );

      expect(await settingsWith(storage).load(), DiagnosticsState.off);
    });

    test('removes a crash switch that was not stored before', () async {
      final storage = MockAuthStorage();
      storage.failWriteKeys.add(DiagnosticsSettings.logsKey);

      await expectLater(
        settingsWith(storage)
            .save(const DiagnosticsState(crashes: true, logs: false)),
        throwsA(anything),
      );

      expect(storage.containsKey(DiagnosticsSettings.crashesKey), isFalse);
    });
  });

  test('copyWith changes only the named switch', () {
    const state = DiagnosticsState(crashes: true, logs: false);

    expect(state.copyWith(logs: true),
        const DiagnosticsState(crashes: true, logs: true));
    expect(state.copyWith(crashes: false), DiagnosticsState.off);
  });

  group('migrates the five-way choice', () {
    const expected = {
      'off': DiagnosticsState.off,
      'crashes': DiagnosticsState(crashes: true, logs: false),
      'logs_24h': DiagnosticsState(crashes: true, logs: false),
      'logs_7d': DiagnosticsState(crashes: true, logs: false),
      'logs_forever': DiagnosticsState(crashes: true, logs: true),
      'something_newer': DiagnosticsState.off,
    };

    for (final MapEntry(key: choice, value: state) in expected.entries) {
      test(choice, () async {
        final storage = MockAuthStorage();
        await storage.write(DiagnosticsSettings.legacyChoiceKey, choice);
        await storage.write(DiagnosticsSettings.legacyUntilKey, '123');

        expect(await settingsWith(storage).load(), state);
        expect(storage.contents[DiagnosticsSettings.crashesKey],
            '${state.crashes}');
        expect(storage.contents[DiagnosticsSettings.logsKey], '${state.logs}');
        expect(
            storage.contents.containsKey(DiagnosticsSettings.legacyChoiceKey),
            isFalse);
        expect(storage.contents.containsKey(DiagnosticsSettings.legacyUntilKey),
            isFalse);
      });
    }
  });

  test('migrates an opted-in crash consent to crash reports on', () async {
    final storage = MockAuthStorage();
    await storage.write(DiagnosticsSettings.legacyCrashKey, 'true');

    expect(await settingsWith(storage).load(),
        const DiagnosticsState(crashes: true, logs: false));
    expect(await storage.read(DiagnosticsSettings.legacyCrashKey), isNull);
    expect(await storage.read(DiagnosticsSettings.crashesKey), 'true');
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

  test('signing out does not clear the switches', () async {
    final storage = MockAuthStorage();
    const state = DiagnosticsState(crashes: true, logs: true);
    await settingsWith(storage).save(state);

    await SettingsService(storage: storage).clearSettings();

    expect(await settingsWith(storage).load(), state);
  });
}
