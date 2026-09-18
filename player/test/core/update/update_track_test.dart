import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/update/update_track.dart';
import 'package:player/core/update/update_track_store.dart';

import '../../test_utils/mock_auth_storage.dart';

void main() {
  group('UpdateTrack', () {
    test('wire names round trip', () {
      for (final track in UpdateTrack.values) {
        expect(UpdateTrack.fromWireName(track.wireName), track);
      }
    });

    // Written out as literals rather than derived from wireName itself: these
    // three strings are the keys scripts/appcast/lib/releases-json.mjs writes
    // into the deployed releases.json feed. A rename on either side breaks
    // the client against the server, and a test that reads its own expected
    // value off the thing it is checking can never catch a rename.
    test("wire names are pinned to the feed's keys", () {
      expect(UpdateTrack.stable.wireName, 'stable');
      expect(UpdateTrack.beta.wireName, 'beta');
      expect(UpdateTrack.dev.wireName, 'dev');
    });

    test('an unknown or missing name is null, not a crash', () {
      expect(UpdateTrack.fromWireName(null), isNull);
      expect(UpdateTrack.fromWireName('nightly'), isNull);
      expect(UpdateTrack.fromWireName(''), isNull);
    });

    test('the dev track never says master to a user', () {
      expect(UpdateTrack.dev.label, 'Dev');
      for (final track in UpdateTrack.values) {
        expect(track.label.toLowerCase(), isNot(contains('master')));
        expect(track.description.toLowerCase(), isNot(contains('master')));
      }
    });
  });

  group('UpdateTrackStore', () {
    test('defaults to stable when nothing is stored', () async {
      final store = UpdateTrackStore(
        settings: SettingsService(storage: MockAuthStorage()),
      );
      expect(await store.read(), UpdateTrack.stable);
    });

    test('round trips a written track', () async {
      final store = UpdateTrackStore(
        settings: SettingsService(storage: MockAuthStorage()),
      );
      await store.write(UpdateTrack.dev);
      expect(await store.read(), UpdateTrack.dev);
    });

    test('a corrupt stored value falls back to stable', () async {
      final storage = MockAuthStorage();
      await storage.write('update_track', 'banana');
      final store =
          UpdateTrackStore(settings: SettingsService(storage: storage));
      expect(await store.read(), UpdateTrack.stable);
    });
  });
}
