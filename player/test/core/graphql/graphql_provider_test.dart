import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/player/device_profile.dart';

/// Always fails [clearAll], to prove a storage error cannot escape
/// [applyDetectedProfile] and break the "detectDeviceProfile never throws"
/// contract it feeds into.
class _ThrowingClearFetchLog extends InMemoryFetchLog {
  @override
  Future<void> clearAll() => throw StateError('boom');
}

void main() {
  group('applyDetectedProfile', () {
    const profile = DeviceProfile.webDefault();
    const otherProfile = DeviceProfile(
      containers: ['mp4'],
      videoCodecs: ['h264'],
      audioCodecs: ['aac'],
      hdrFormats: [],
    );

    test('writes the profile onto the holder', () async {
      final holder = DeviceProfileHolder();
      final fetchLog = InMemoryFetchLog();

      await applyDetectedProfile(holder, profile, fetchLog);

      expect(holder.profile, profile);
    });

    test('clears the fetch log on the null-to-non-null transition', () async {
      final holder = DeviceProfileHolder();
      final fetchLog = InMemoryFetchLog({
        QueryKeys.home: DateTime(2026, 8, 22),
        QueryKeys.favorites: DateTime(2026, 8, 22),
      });

      await applyDetectedProfile(holder, profile, fetchLog);

      expect(fetchLog.lastFetchedAt(QueryKeys.home), isNull);
      expect(fetchLog.lastFetchedAt(QueryKeys.favorites), isNull);
    });

    test('does not clear the fetch log again on a subsequent write', () async {
      final holder = DeviceProfileHolder();
      final fetchLog = InMemoryFetchLog();

      // First write: null -> non-null, clears (nothing to observe yet, the
      // log starts empty).
      await applyDetectedProfile(holder, profile, fetchLog);

      // Simulate a later write landing on an already-resolved holder, and
      // seed an entry that a second clear would wipe.
      await fetchLog.record(QueryKeys.home, DateTime(2026, 8, 22));
      await applyDetectedProfile(holder, otherProfile, fetchLog);

      expect(fetchLog.lastFetchedAt(QueryKeys.home), isNotNull,
          reason: 'a write onto an already-set holder must not clear again');
      // The second write still lands, even though it did not trigger a clear.
      expect(holder.profile, otherProfile);
    });

    test('a failing clearAll does not propagate or block the write', () async {
      final holder = DeviceProfileHolder();
      final fetchLog = _ThrowingClearFetchLog();

      await expectLater(
        applyDetectedProfile(holder, profile, fetchLog),
        completes,
      );
      expect(holder.profile, profile);
    });
  });
}
