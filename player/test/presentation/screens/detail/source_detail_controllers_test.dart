import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/fetch_log.dart';
import 'package:player/core/sources/cache/source_cache.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/detail/detail_actions.dart';
import 'package:player/presentation/screens/detail/detail_links.dart';
import 'package:player/presentation/screens/detail/detail_providers.dart';
import 'package:player/presentation/screens/detail/source_detail_controllers.dart';

import '../sources/fake_media_source.dart';

ProviderContainer _container(FakeMediaSource source) {
  final c = ProviderContainer(overrides: [
    mediaSourceProvider(fakeSourceId).overrideWithValue(source),
  ]);
  addTearDown(c.dispose);
  return c;
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('a source movie loads into a MovieView', () async {
    final c = _container(FakeDetailSource());
    final target = SourceTarget(fakeMovie(1).ref);
    final sub = c.listen(movieViewProvider(target), (_, __) {});
    await _settle();
    expect(sub.read().value?.title, 'Invented Film 1');
  });

  test('marking a season watched is one call on the season', () async {
    final source = FakeDetailSource();
    final c = _container(source);
    final DetailTarget show = SourceTarget(fakeShow.ref);
    final key = (show: show, seasonNumber: 1);
    final sub = c.listen(seasonEpisodesViewProvider(key), (_, __) {});
    await _settle();
    expect(sub.read().value, hasLength(2));
    await c.read(seasonActionsProvider(key)).setSeasonWatched(true);
    expect(source.watchedCalls, [(fakeSeason.ref, true)]);
    expect(sub.read().value?.every((e) => e.watched), isTrue);
  });

  test('this and previous marks each earlier episode once, in order', () async {
    final source = FakeDetailSource();
    final c = _container(source);
    final DetailTarget show = SourceTarget(fakeShow.ref);
    final key = (show: show, seasonNumber: 1);
    final sub = c.listen(seasonEpisodesViewProvider(key), (_, __) {});
    await _settle();
    final second = sub.read().value![1];
    await c
        .read(seasonActionsProvider(key))
        .episode(second, EpisodeWatchedAction.thisAndPrevious);
    expect(source.watchedCalls, [
      (fakeEpisode(1).ref, true),
      (fakeEpisode(2).ref, true),
    ]);
  });

  test('a failed episode write restores the list and rethrows', () async {
    final source = _FailingWatchedSource();
    final c = _container(source);
    final DetailTarget show = SourceTarget(fakeShow.ref);
    final key = (show: show, seasonNumber: 1);
    final sub = c.listen(seasonEpisodesViewProvider(key), (_, __) {});
    await _settle();
    final first = sub.read().value!.first;
    await expectLater(
      c
          .read(seasonActionsProvider(key))
          .episode(first, EpisodeWatchedAction.watched),
      throwsException,
    );
    expect(sub.read().value?.any((e) => e.watched), isFalse);
  });

  test('a partial this-and-previous failure stops and refetches', () async {
    final source = _SecondWriteFailsSource();
    final c = _container(source);
    final DetailTarget show = SourceTarget(fakeShow.ref);
    final key = (show: show, seasonNumber: 1);
    final sub = c.listen(seasonEpisodesViewProvider(key), (_, __) {});
    await _settle();
    final second = sub.read().value![1];
    final loads = source.seasonChildrenCalls;
    await expectLater(
      c
          .read(seasonActionsProvider(key))
          .episode(second, EpisodeWatchedAction.thisAndPrevious),
      throwsException,
    );
    await _settle();
    expect(source.watchedCalls, [(fakeEpisode(1).ref, true)]);
    expect(source.seasonChildrenCalls, greaterThan(loads));
  });

  test('a missing capability fails the future instead of throwing', () async {
    final c = _container(FakeMediaSource());
    final target = SourceTarget(fakeMovie(1).ref);
    c.listen(movieViewProvider(target), (_, __) {});
    await _settle();
    final future = c.read(movieActionsProvider(target)).toggleFavorite();
    await expectLater(future, throwsStateError);
  });

  test('a late next up keeps an optimistic favorite', () async {
    final source = _SlowNextUpSource();
    final c = _container(source);
    final target = SourceTarget(fakeShow.ref);
    final sub = c.listen(showViewProvider(target), (_, __) {});
    await _settle();
    // The favorite write stays pending, so the show has not been refetched
    // when next up lands.
    final write = c.read(showActionsProvider(target)).toggleFavorite();
    source.release.complete();
    await _settle();
    expect(sub.read().value?.nextUpEpisodeId, 'e2');
    expect(sub.read().value?.isFavorite, isTrue);
    source.favoriteGate.complete();
    await write;
  });

  test('a season fills the episode season number from the request', () async {
    final c = _container(_NoParentIndexSource());
    final DetailTarget show = SourceTarget(fakeShow.ref);
    final key = (show: show, seasonNumber: 1);
    final sub = c.listen(seasonEpisodesViewProvider(key), (_, __) {});
    await _settle();
    expect(sub.read().value?.map((e) => e.seasonNumber), [1, 1]);
  });

  test('next up lands after the header', () async {
    final source = FakeDetailSource();
    final c = _container(source);
    final target = SourceTarget(fakeShow.ref);
    final seen = <String?>[];
    c.listen(
      showViewProvider(target),
      (_, next) => seen.add(next.value?.nextUpEpisodeId),
      fireImmediately: true,
    );
    await _settle();
    expect(seen.whereType<String>().last, 'e2');
  });

  test('a failed next up keeps the show', () async {
    final source = FakeDetailSource()..nextUpError = Exception('down');
    final c = _container(source);
    final target = SourceTarget(fakeShow.ref);
    final sub = c.listen(showViewProvider(target), (_, __) {});
    await _settle();
    expect(sub.read().value?.title, 'Invented Series');
    expect(sub.read().value?.nextUpEpisodeId, isNull);
  });

  test('a failed favorite restores the view and rethrows', () async {
    final source = FakeDetailSource()..favoriteError = Exception('down');
    final c = _container(source);
    final target = SourceTarget(fakeMovie(1).ref);
    final sub = c.listen(movieViewProvider(target), (_, __) {});
    await _settle();
    await expectLater(
      c.read(movieActionsProvider(target)).toggleFavorite(),
      throwsException,
    );
    expect(sub.read().value?.isFavorite, isFalse);
  });

  test('a favorite toggle reaches the source', () async {
    final source = FakeDetailSource();
    final c = _container(source);
    final target = SourceTarget(fakeMovie(1).ref);
    c.listen(movieViewProvider(target), (_, __) {});
    await _settle();
    await c.read(movieActionsProvider(target)).toggleFavorite();
    expect(source.favoriteCalls, [(fakeMovie(1).ref, true)]);
  });

  test('marking a movie watched is optimistic and calls the source', () async {
    final source = FakeDetailSource();
    final c = _container(source);
    final target = SourceTarget(fakeMovie(1).ref);
    final sub = c.listen(movieViewProvider(target), (_, __) {});
    await _settle();
    final write = c.read(movieActionsProvider(target)).setWatched(true);
    expect(sub.read().value?.isWatched, isTrue);
    await write;
    expect(source.watchedCalls, [(fakeMovie(1).ref, true)]);
  });

  test('similar is empty without the capability and lists with it', () async {
    // A listener keeps the stream provider alive until its first value.
    final plain = _container(FakeMediaSource());
    plain.listen(sourceSimilarProvider(fakeMovie(1).ref), (_, __) {});
    expect(
      await plain.read(sourceSimilarProvider(fakeMovie(1).ref).future),
      isEmpty,
    );
    final rich = _container(FakeDetailSource());
    rich.listen(sourceSimilarProvider(fakeMovie(1).ref), (_, __) {});
    final items =
        await rich.read(sourceSimilarProvider(fakeMovie(1).ref).future);
    expect(items.single.title, 'Invented Film 2');
  });

  test('source links carry what the player needs for Up Next', () async {
    final c = _container(FakeDetailSource());
    final DetailTarget show = SourceTarget(fakeShow.ref);
    final key = (show: show, seasonNumber: 1);
    final sub = c.listen(seasonEpisodesViewProvider(key), (_, __) {});
    await _settle();
    final episode = sub.read().value!.first;
    const file = MediaFile(id: 'part-1', directPlaySupported: true);
    final uri = Uri.parse(
      episodePlayerLocation(episode, file, resumeSeconds: 90),
    );
    expect(uri.path, '/s/${fakeSourceId.value}/player/e1');
    expect(uri.queryParameters, {
      'kind': 'episode',
      'fileId': file.id,
      'title': episode.fullTitle,
      'showId': 's1',
      'seasonNumber': '1',
      'resume': '90',
    });
  });

  test('leaving a show before its first load finishes raises no error',
      () async {
    final source = FakeDetailSource()..itemHold = Completer<void>();
    final c = ProviderContainer(overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(source),
    ]);
    c.listen(showViewProvider(SourceTarget(fakeShow.ref)), (_, __) {});
    await _settle();
    // The item fetch is still held: disposing now completes the provider
    // futures the show build awaits with a disposed-during-loading error.
    c.dispose();
    await pumpEventQueue();
    source.itemHold!.complete();
    await pumpEventQueue();
  });

  test('a real server error still reaches the show view', () async {
    final source = FakeDetailSource()
      ..itemError = const SourceException.notFound();
    final c = _container(source);
    final sub =
        c.listen(showViewProvider(SourceTarget(fakeShow.ref)), (_, __) {});
    await _settle();
    // Riverpod reports its automatic retry as a loading state, so the proof
    // that the error surfaced is the retry refetching the item (the first
    // retry fires after 200ms).
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sub.read().hasValue, isFalse);
    expect(source.itemCalls, greaterThan(1),
        reason: 'the build is current, so the error is not swallowed');
  });

  test('a movie view updates when the fresh item lands after the cached one',
      () async {
    final cache = InMemorySourceCache();
    final log = InMemoryFetchLog();
    final source = FakeDetailSource();
    ProviderContainer mount() {
      final c = ProviderContainer(overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(source),
        sourceCacheProvider.overrideWithValue(cache),
        fetchLogProvider.overrideWithValue(log),
      ]);
      addTearDown(c.dispose);
      return c;
    }

    final target = SourceTarget(fakeMovie(1).ref);
    final first = mount();
    first.listen(movieViewProvider(target), (_, __) {});
    await _settle();

    source.titleSuffix = ' (remastered)';
    final second = mount();
    final views = <String>[];
    second.listen(movieViewProvider(target), (_, next) {
      if (next.value case final v?) views.add(v.title);
    }, fireImmediately: true);
    await _settle();
    expect(views.first, isNot(endsWith('(remastered)')),
        reason: 'the cached item paints first');
    expect(views.last, endsWith('(remastered)'));
  });
}

class _FailingWatchedSource extends FakeDetailSource {
  @override
  Future<void> setWatched(ItemRef ref, bool watched) async =>
      throw Exception('down');
}

class _NoParentIndexSource extends FakeDetailSource {
  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) async =>
      parent.kind == ItemKind.season
          ? Page(items: [
              for (final n in [1, 2])
                ItemSummary(
                  ref: fakeEpisode(n).ref,
                  title: 'Invented Episode $n',
                  index: n,
                  defaultVersionId: 'v$n',
                ),
            ])
          : super.children(parent, cursor: cursor);
}

class _SecondWriteFailsSource extends FakeDetailSource {
  int seasonChildrenCalls = 0;

  @override
  Future<Page<ItemSummary>> children(ItemRef parent, {Cursor? cursor}) {
    if (parent.kind == ItemKind.season) seasonChildrenCalls++;
    return super.children(parent, cursor: cursor);
  }

  @override
  Future<void> setWatched(ItemRef ref, bool watched) async {
    if (watchedCalls.isNotEmpty) throw Exception('down');
    watchedCalls.add((ref, watched));
  }
}

class _SlowNextUpSource extends FakeDetailSource {
  final release = Completer<void>();
  final favoriteGate = Completer<void>();

  @override
  Future<void> setFavorite(ItemRef ref, bool favorite) async {
    await favoriteGate.future;
    return super.setFavorite(ref, favorite);
  }

  @override
  Future<ItemSummary?> nextUp(ItemRef show) async {
    await release.future;
    return super.nextUp(show);
  }
}
