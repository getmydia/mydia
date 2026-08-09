import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/user_settings.dart';

void main() {
  group('UserSettings', () {
    test('round-trips through JSON', () {
      const settings = UserSettings(
        serverUrl: 'mydia.local:4000',
        username: 'admin',
        defaultQuality: '1080p',
        autoSkipSegments: true,
      );

      final restored = UserSettings.fromJson(settings.toJson());

      expect(restored.serverUrl, 'mydia.local:4000');
      expect(restored.username, 'admin');
      expect(restored.defaultQuality, '1080p');
      expect(restored.autoSkipSegments, isTrue);
    });

    test('carries no auto-play-next state', () {
      const settings = UserSettings(serverUrl: '', username: '');

      expect(settings.toJson().keys, isNot(contains('autoPlayNextEpisode')));
    });

    test('ignores a stale auto-play-next key from older stored JSON', () {
      final restored = UserSettings.fromJson({
        'serverUrl': 'host',
        'username': 'admin',
        'defaultQuality': 'auto',
        'autoSkipSegments': false,
        'autoPlayNextEpisode': true,
      });

      expect(restored.username, 'admin');
      expect(restored.toJson().keys, isNot(contains('autoPlayNextEpisode')));
    });

    test('copyWith leaves untouched fields alone', () {
      const settings = UserSettings(
        serverUrl: 'host',
        username: 'admin',
        defaultQuality: '720p',
      );

      final updated = settings.copyWith(autoSkipSegments: true);

      expect(updated.defaultQuality, '720p');
      expect(updated.username, 'admin');
      expect(updated.autoSkipSegments, isTrue);
    });
  });
}
