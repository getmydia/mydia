import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/presentation/screens/calendar/calendar_view_mode.dart';
import 'package:player/presentation/screens/settings/settings_controller.dart';

import '../../../test_utils/mock_auth_storage.dart';

/// A keychain that refuses every read and write.
class _RefusingStorage extends MockAuthStorage {
  @override
  Future<String?> read(String key) async =>
      throw Exception('keyring unavailable');

  @override
  Future<void> write(String key, String value) async =>
      throw Exception('keyring unavailable');
}

ProviderContainer _container(MockAuthStorage storage) {
  final container = ProviderContainer(
    overrides: [
      settingsServiceProvider
          .overrideWithValue(SettingsService(storage: storage)),
    ],
  );
  addTearDown(container.dispose);
  // The provider auto-disposes; a listener keeps it alive across awaits.
  container.listen(calendarViewModeControllerProvider, (previous, next) {});
  return container;
}

Future<CalendarViewMode> _load(ProviderContainer container) =>
    container.read(calendarViewModeControllerProvider.future);

void main() {
  group('CalendarViewMode.decode', () {
    test('reads back each stored mode', () {
      expect(CalendarViewMode.decode('week'), CalendarViewMode.week);
      expect(CalendarViewMode.decode('agenda'), CalendarViewMode.agenda);
    });

    test('defaults to week when nothing is stored', () {
      expect(CalendarViewMode.decode(null), CalendarViewMode.week);
    });

    test('defaults to week for a value it does not know', () {
      expect(CalendarViewMode.decode('month'), CalendarViewMode.week);
    });

    test('decodes whatever encode wrote', () {
      for (final mode in CalendarViewMode.values) {
        expect(CalendarViewMode.decode(mode.encode()), mode);
      }
    });
  });

  group('CalendarViewModeController', () {
    test('starts on week when nothing is stored', () async {
      final container = _container(MockAuthStorage());

      expect(await _load(container), CalendarViewMode.week);
    });

    test('restores the stored choice', () async {
      final storage = MockAuthStorage()
        ..seedData({'calendar_view_mode': 'agenda'});
      final container = _container(storage);

      expect(await _load(container), CalendarViewMode.agenda);
    });

    test('falls back to week when storage cannot be read', () async {
      final container = _container(_RefusingStorage());

      expect(await _load(container), CalendarViewMode.week);
    });

    test('select switches the mode and stores it', () async {
      final storage = MockAuthStorage();
      final container = _container(storage);
      await _load(container);

      await container
          .read(calendarViewModeControllerProvider.notifier)
          .select(CalendarViewMode.agenda);

      expect(
        container.read(calendarViewModeControllerProvider).value,
        CalendarViewMode.agenda,
      );
      expect(storage.contents['calendar_view_mode'], 'agenda');
    });

    test('select keeps the choice when storage refuses the write', () async {
      final container = _container(_RefusingStorage());
      await _load(container);

      await container
          .read(calendarViewModeControllerProvider.notifier)
          .select(CalendarViewMode.agenda);

      expect(
        container.read(calendarViewModeControllerProvider).value,
        CalendarViewMode.agenda,
      );
    });
  });
}
