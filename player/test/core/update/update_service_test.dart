import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/update/update_feed_client.dart';
import 'package:player/core/update/update_service.dart';
import 'package:player/core/update/update_track.dart';

/// A feed client that hands back a canned entry and records what it was
/// asked for, so a test can assert the track UpdateService receives is the
/// one it actually forwards, not the platform.
///
/// Implements rather than extends UpdateFeedClient: its private Dio and feed
/// URL fields belong to a different library and are not part of what this
/// fake needs to provide.
class _FakeFeedClient implements UpdateFeedClient {
  _FakeFeedClient(this._entry);

  final FeedEntry? _entry;
  UpdateTrack? lastTrack;
  String? lastPlatform;
  int calls = 0;

  @override
  Future<FeedEntry?> fetch({
    required UpdateTrack track,
    required String platform,
  }) async {
    calls++;
    lastTrack = track;
    lastPlatform = platform;
    return _entry;
  }
}

FeedEntry _entry(String version) => FeedEntry(
      version: version,
      build: 1,
      url: 'https://example.invalid/build',
      size: 1000,
      sha256: null,
      notesUrl: 'https://example.invalid/notes',
      publishedAt: DateTime.utc(2026, 9, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Backs UpdateService's rate-limit timestamp with an in-memory mock
    // rather than the real secure-storage platform channel, which is not
    // registered under flutter test.
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('an entry newer than the running version is offered', () async {
    final client = _FakeFeedClient(_entry('0.16.0'));
    final service = UpdateService(client: client);

    final update = await service.checkForUpdate(
      currentVersion: '0.15.0',
      track: UpdateTrack.stable,
      force: true,
    );

    expect(update, isNotNull);
    expect(update!.version, '0.16.0');
  });

  test('an equal version is not offered', () async {
    final client = _FakeFeedClient(_entry('0.15.0'));
    final service = UpdateService(client: client);

    final update = await service.checkForUpdate(
      currentVersion: '0.15.0',
      track: UpdateTrack.stable,
      force: true,
    );

    expect(update, isNull);
  });

  test('an older version is not offered', () async {
    final client = _FakeFeedClient(_entry('0.14.0'));
    final service = UpdateService(client: client);

    final update = await service.checkForUpdate(
      currentVersion: '0.15.0',
      track: UpdateTrack.stable,
      force: true,
    );

    expect(update, isNull);
  });

  test('a null entry from the feed is handled, not thrown', () async {
    final client = _FakeFeedClient(null);
    final service = UpdateService(client: client);

    final update = await service.checkForUpdate(
      currentVersion: '0.15.0',
      track: UpdateTrack.dev,
      force: true,
    );

    expect(update, isNull);
    expect(client.calls, 1);
  });

  test('the requested track is passed through to the client, not ignored',
      () async {
    final client = _FakeFeedClient(_entry('0.16.0'));
    final service = UpdateService(client: client);

    await service.checkForUpdate(
      currentVersion: '0.15.0',
      track: UpdateTrack.beta,
      force: true,
    );

    expect(client.lastTrack, UpdateTrack.beta);
  });
}
