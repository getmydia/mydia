import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/playback/local_playback_progress.dart';
import 'package:player/core/playback/playback_progress_store.dart';
import 'package:player/core/player/local_progress_reporter.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';

void main() {
  test('saves progress under the progress key and tells the lists', () async {
    final store = InMemoryPlaybackProgressStore();
    var saved = 0;
    const item = ItemRef(
        sourceId: SourceId('files:local'),
        kind: ItemKind.episode,
        externalId: '201-1-2');
    final reporter = LocalProgressReporter(
      store: store,
      item: item,
      onSaved: () async => saved++,
      clock: () => DateTime.utc(2026, 1, 2),
    );

    await reporter.sendProgress(
        positionSeconds: 90, durationSeconds: 1200, paused: false);

    final record = store.get(progressKey(item))!;
    expect(record.positionSeconds, 90);
    expect(record.durationSeconds, 1200);
    expect(record.mediaType, 'episode');
    expect(record.updatedAt, DateTime.utc(2026, 1, 2));
    expect(saved, 1);

    await reporter.sendStopped(positionSeconds: 100, durationSeconds: 1200);
    expect(store.get(progressKey(item))!.positionSeconds, 100);
    expect(saved, 2);
    reporter.dispose();
  });
}
