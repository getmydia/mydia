import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/fetch_log.dart';
import 'package:player/core/sources/cache/source_cache.dart';
import 'package:player/core/sources/cache/source_codecs.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/media_stream.dart';
import 'package:player/domain/sources/collection.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/calendar/calendar_window.dart';
import 'package:player/presentation/screens/sources/source_browse_providers.dart';

import 'fake_capable_source.dart';
import 'fake_media_source.dart';

const _stored = SourceCollection(
    sourceId: fakeSourceId, id: 'c0', name: 'Stored Shelf', itemCount: 1);
const _live = SourceCollection(
    sourceId: fakeSourceId, id: 'c1', name: 'Live Shelf', itemCount: 2);

/// Answers [collections] only when [release] completes.
class _SlowCollectionsSource extends FakeCapableSource {
  final release = Completer<void>();

  @override
  Future<List<SourceCollection>> collections() async {
    await release.future;
    return super.collections();
  }
}

void main() {
  ProviderContainer containerFor(FakeMediaSource source,
      {InMemorySourceCache? cache}) {
    final container = ProviderContainer(overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(source),
      if (cache != null) sourceCacheProvider.overrideWithValue(cache),
      if (cache != null)
        fetchLogProvider.overrideWithValue(InMemoryFetchLog({
          SourceKeys.collections(fakeSourceId):
              DateTime.now().subtract(const Duration(hours: 1)),
        })),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  Future<T> firstValue<T>(ProviderContainer c, StreamProvider<T> provider) {
    c.listen(provider, (_, __) {});
    return c.read(provider.future);
  }

  test('collections emit the stored answer before the live one', () async {
    final cache = InMemorySourceCache();
    await cache.write(SourceKeys.collections(fakeSourceId),
        encodeCollections(const [_stored]), DateTime.now());
    final source = _SlowCollectionsSource()..collectionsResult = const [_live];
    final container = containerFor(source, cache: cache);

    final seen = <List<SourceCollection>>[];
    container.listen(sourceCollectionsProvider(fakeSourceId), (_, next) {
      if (next case AsyncData(:final value)) seen.add(value);
    });
    await pumpEventQueue();
    expect(seen.map((l) => l.single.name), ['Stored Shelf'],
        reason: 'served from the cache while the fetch is held');

    source.release.complete();
    await pumpEventQueue();
    expect(seen.map((l) => l.single.name), ['Stored Shelf', 'Live Shelf']);
  });

  test('the calendar asks for the window around today', () async {
    final source = FakeCapableSource()
      ..calendarResult = [fakeMovie(1), fakeMovie(2)];
    final container = containerFor(source);

    final before = calendarWindow(DateTime.now());
    final items =
        await firstValue(container, sourceCalendarProvider(fakeSourceId));
    final after = calendarWindow(DateTime.now());

    expect(items, hasLength(2));
    expect(source.calls, hasLength(1));
    final ok = [
      'calendar(${before.start}, ${before.end})',
      'calendar(${after.start}, ${after.end})',
    ];
    expect(ok, contains(source.calls.single));
  });

  test('recently added comes from a source that has it', () async {
    final source = FakeCapableSource()..recentlyAddedResult = [fakeMovie(4)];
    final container = containerFor(source);
    final items =
        await firstValue(container, sourceRecentlyAddedProvider(fakeSourceId));
    expect(items.single.ref.externalId, 'm4');
  });

  test('media info is read from the source, uncached', () async {
    final source = FakeCapableSource()
      ..mediaInfoResult = const [MediaFileInfo(id: 'f1')];
    final container = containerFor(source);
    final item = fakeMovie(1).ref;
    container.listen(sourceMediaInfoProvider(item), (_, __) {});

    final files = await container.read(sourceMediaInfoProvider(item).future);

    expect(files.single.id, 'f1');
    expect(source.calls, ['mediaInfo(m1)']);
  });

  test('media info is unsupported for a source without the capability',
      () async {
    final container = containerFor(FakeMediaSource());
    final item = fakeMovie(1).ref;
    container.listen(sourceMediaInfoProvider(item), (_, __) {});

    await expectLater(
      container.read(sourceMediaInfoProvider(item).future),
      throwsA(isA<SourceException>()
          .having((e) => e.kind, 'kind', SourceErrorKind.unsupported)),
    );
  });

  test('every listing is empty, with no call, without the capability',
      () async {
    final container = containerFor(FakeMediaSource());
    expect(await firstValue(container, sourceCollectionsProvider(fakeSourceId)),
        isEmpty);
    expect(await firstValue(container, sourceCalendarProvider(fakeSourceId)),
        isEmpty);
    expect(
        await firstValue(container, sourceRecentlyAddedProvider(fakeSourceId)),
        isEmpty);
  });
}
