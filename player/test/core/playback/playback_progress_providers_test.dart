import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_providers.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';

import '../../presentation/screens/sources/fake_media_source.dart';
import '../../test_utils/mydia_test_source.dart';

/// A Mydia source as the flush sees it: a status that can move and a place
/// to push positions to.
class _MydiaSyncSource extends FakeMediaSource implements ProgressSync {
  final pushed = <String>[];

  @override
  Source get source => testMydiaSource;

  @override
  Future<void> pushProgress(
    ItemRef ref, {
    required int positionSeconds,
    required int durationSeconds,
    required bool watched,
  }) async {
    pushed.add(ref.externalId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a Mydia source coming back into reach gets its offline positions',
      () async {
    final store = InMemoryPlaybackProgressStore();
    await store.save(LocalPlaybackProgress(
      sourceId: testMydiaSourceId.value,
      mediaId: '7',
      mediaType: 'movie',
      positionSeconds: 30,
      durationSeconds: 100,
      updatedAt: DateTime(2026),
    ));
    final mydia = _MydiaSyncSource()
      ..setStatus(SourceConnectionStatus.unreachable);

    final container = ProviderContainer(overrides: [
      playbackProgressStoreProvider.overrideWith((ref) async => store),
      thirdPartySourcesProvider.overrideWithValue([testMydiaSource]),
      mediaSourceProvider(testMydiaSourceId).overrideWithValue(mydia),
    ]);
    addTearDown(container.dispose);

    container.read(sourceProgressFlushProvider);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(mydia.pushed, isEmpty, reason: 'unreachable: nothing to push to');

    mydia.setStatus(SourceConnectionStatus.remote);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(mydia.pushed, ['7']);
    expect(store.unsynced(), isEmpty);
  });
}
