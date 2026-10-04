import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/presentation/screens/sources/source_browse_providers.dart';

import 'fake_media_source.dart';

/// Holds every follow-up page (one with a cursor) until released.
class _GatedSource extends FakeMediaSource {
  _GatedSource() : super(movieCount: 130);

  final gate = Completer<void>();
  Error? followUpError;

  @override
  Future<Page<ItemSummary>> browse(LibraryRef library, BrowseQuery query,
      {Cursor? cursor}) async {
    if (cursor != null) {
      await gate.future;
      if (followUpError case final e?) throw e;
    }
    return super.browse(library, query, cursor: cursor);
  }
}

void main() {
  ProviderContainer containerFor(FakeMediaSource source) {
    final container = ProviderContainer(overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(source),
    ]);
    addTearDown(container.dispose);
    container.listen(libraryBrowseProvider(FakeMediaSource.movies), (_, __) {});
    return container;
  }

  test('a page requested for the old query is dropped after setQuery',
      () async {
    final source = _GatedSource();
    final container = containerFor(source);
    final provider = libraryBrowseProvider(FakeMediaSource.movies);
    await container.read(provider.future);
    final notifier = container.read(provider.notifier);

    final loading = notifier.loadMore();
    await notifier.setQuery(const BrowseQuery(sortId: 'added'));
    source.gate.complete();
    await loading;

    final state = container.read(provider).requireValue;
    expect(state.query.sortId, 'added');
    expect(state.items, hasLength(60), reason: "only the new query's page");
    expect(state.loadingMore, isFalse);
  });

  test('a failure that is not a SourceException resets loadingMore', () async {
    final source = _GatedSource()..followUpError = StateError('boom');
    final container = containerFor(source);
    final provider = libraryBrowseProvider(FakeMediaSource.movies);
    await container.read(provider.future);

    final loading = container.read(provider.notifier).loadMore();
    source.gate.complete();
    await loading;

    expect(container.read(provider).requireValue.loadingMore, isFalse);
  });
}
