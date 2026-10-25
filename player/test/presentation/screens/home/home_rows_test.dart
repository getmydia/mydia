// copyWithPrevious is how Riverpod itself builds a provider that reloads
// after an error; no public API produces that state.
// ignore_for_file: invalid_use_of_internal_member

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/mydia_mapping.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/l10n/gen/app_localizations_en.dart';
import 'package:player/presentation/screens/home/home_rows.dart';

import '../../../domain/merged/fake_merged_source.dart';

const _down = SourceException.unreachable();

Library lib(Source s, String id, String title) => Library(
    ref: LibraryRef(sourceId: s.id, id: id),
    title: title,
    kind: LibraryKind.movies,
    sortOptions: const []);

HomeFeeds feeds(
  Source s, {
  List<ItemSummary> resuming = const [],
  List<ItemSummary> recent = const [],
  List<ItemSummary> favs = const [],
  List<Library> libraries = const [],
  Map<LibraryRef, AsyncValue<List<ItemSummary>>> previews = const {},
  bool cwFails = false,
  bool recentFails = false,
  bool librariesFail = false,
  bool loading = false,
}) {
  AsyncValue<T> v<T>(T value, bool fails) => loading
      ? AsyncLoading<T>()
      : fails
          ? AsyncError<T>(_down, StackTrace.empty)
          : AsyncData(value);
  return HomeFeeds(
    id: s.id,
    name: s.displayName,
    continueWatching: v(resuming, cwFails),
    recentlyAdded: v(recent, recentFails),
    favorites: AsyncData(favs),
    libraries: v(libraries, librariesFail),
    previews: previews,
  );
}

void main() {
  final a = fakeServer('a'), b = fakeServer('b');

  test('loading until every server has its first rows', () {
    final rows = buildHomeRows([feeds(a), feeds(b, loading: true)]);
    expect(rows.loading, isTrue);
  });

  test('a feed loading again after an error is not settled', () {
    final base = feeds(a);
    final retrying = HomeFeeds(
      id: base.id,
      name: base.name,
      continueWatching: base.continueWatching,
      recentlyAdded: base.recentlyAdded,
      favorites: base.favorites,
      libraries: const AsyncLoading<List<Library>>().copyWithPrevious(
          const AsyncError<List<Library>>(_down, StackTrace.empty)),
    );
    expect(retrying.libraries.hasError, isTrue);
    expect(retrying.libraries.isLoading, isTrue);
    final rows = buildHomeRows([retrying]);
    expect(rows.loading, isTrue);
    expect(rows.unavailable, isEmpty);
    expect(rows.error, isNull);
  });

  test('a feed that has a value stays settled while refreshing', () {
    final base = feeds(a, resuming: [item(a, 'r1')]);
    final refreshing = HomeFeeds(
      id: base.id,
      name: base.name,
      continueWatching: const AsyncLoading<List<ItemSummary>>()
          .copyWithPrevious(AsyncData([item(a, 'r1')])),
      recentlyAdded: base.recentlyAdded,
      favorites: base.favorites,
      libraries: base.libraries,
    );
    final rows = buildHomeRows([refreshing]);
    expect(rows.loading, isFalse);
    expect(rows.continueWatching, hasLength(1));
  });

  test('hero is the first Continue Watching item', () {
    final rows = buildHomeRows([
      feeds(a,
          resuming: [item(a, 'r1', lastPlayedAt: DateTime.utc(2024))],
          recent: [item(a, 'm1', addedAt: DateTime.utc(2024))]),
    ]);
    expect(rows.hero?.ref.externalId, 'r1');
  });

  test('without Continue Watching the hero is the newest movie', () {
    final rows = buildHomeRows([
      feeds(a, recent: [
        item(a, 's1', kind: ItemKind.show, addedAt: DateTime.utc(2024, 2)),
        item(a, 'm1', addedAt: DateTime.utc(2024, 1)),
      ]),
    ]);
    expect(rows.hero?.ref.externalId, 'm1');
  });

  test('with no movies the hero is the newest item', () {
    final rows = buildHomeRows([
      feeds(a, recent: [
        item(a, 's1', kind: ItemKind.show, addedAt: DateTime.utc(2024)),
      ]),
    ]);
    expect(rows.hero?.ref.externalId, 's1');
  });

  test('Recently Added splits into movies and TV', () {
    final rows = buildHomeRows([
      feeds(a, recent: [
        item(a, 'm1', addedAt: DateTime.utc(2024, 2)),
        item(a, 's1', kind: ItemKind.show, addedAt: DateTime.utc(2024, 1)),
      ]),
    ]);
    expect(rows.recentMovies.map((i) => i.ref.externalId), ['m1']);
    expect(rows.recentShows.map((i) => i.ref.externalId), ['s1']);
  });

  test('one server: library rows keep their own titles, no labels', () {
    final rows = buildHomeRows([
      feeds(a, libraries: [lib(a, 'movies', 'Films')]),
    ]);
    expect(rows.labelled, isFalse);
    expect(rows.libraries.single.title(AppLocalizationsEn()), 'Films');
  });

  test('two servers: library rows name their server, in scope order', () {
    final rows = buildHomeRows([
      feeds(a, libraries: [lib(a, 'movies', 'Films')]),
      feeds(b, libraries: [lib(b, 'movies', 'Films'), lib(b, 'x', 'Extras')]),
    ]);
    expect(rows.labelled, isTrue);
    expect(rows.libraries.map((r) => r.title(AppLocalizationsEn())),
        ['Films · Server a', 'Films · Server b', 'Extras · Server b']);
  });

  test('a library row is hidden once its preview loads empty', () {
    final films = lib(a, 'movies', 'Films'), empty = lib(a, 'e', 'Empty');
    final rows = buildHomeRows([
      feeds(a, libraries: [
        films,
        empty
      ], previews: {
        films.ref: AsyncData([item(a, 'm1')]),
        empty.ref: const AsyncData([]),
      }),
    ]);
    expect(rows.libraries.map((r) => r.title(AppLocalizationsEn())), ['Films']);
    expect(rows.libraries.single.items.single.ref.externalId, 'm1');
  });

  test('a library row whose preview is loading stays, empty', () {
    final films = lib(a, 'movies', 'Films');
    final rows = buildHomeRows([
      feeds(a, libraries: [films], previews: {films.ref: const AsyncLoading()}),
    ]);
    expect(rows.libraries.single.items, isEmpty);
  });

  test('a server whose libraries fail is unavailable and its items drop', () {
    final rows = buildHomeRows([
      feeds(a, recent: [item(a, 'm1', addedAt: DateTime.utc(2024))]),
      feeds(b,
          recent: [item(b, 'm2', addedAt: DateTime.utc(2024))],
          librariesFail: true),
    ]);
    expect(rows.unavailable, [b.id]);
    expect(rows.recentMovies.map((i) => i.ref.externalId), ['m1']);
    expect(rows.error, isNull);
  });

  test('both row feeds failing makes a server unavailable; one does not', () {
    final rows = buildHomeRows([
      feeds(a, cwFails: true),
      feeds(b, cwFails: true, recentFails: true),
    ]);
    expect(rows.unavailable, [b.id]);
  });

  test('every server unavailable is an error, not an empty page', () {
    final rows = buildHomeRows([feeds(a, librariesFail: true)]);
    expect(rows.error, _down);
  });

  test('no servers is empty, not an error', () {
    final rows = buildHomeRows(const []);
    expect(rows.loading, isFalse);
    expect(rows.error, isNull);
    expect(rows.isEmpty, isTrue);
  });

  test('a next card for a show watched today outranks a stale resume', () {
    Map<String, dynamic> card(String id, String type,
            {String? activity, String? watchedAt, int position = 0}) =>
        {
          'id': id,
          'type': type,
          'title': id,
          if (type == 'EPISODE') 'showId': 'show-$id',
          if (activity != null) 'lastActivityAt': activity,
          'progress': {
            'positionSeconds': position,
            'durationSeconds': 1440,
            'percentage': 0.0,
            'watched': false,
            'lastWatchedAt': watchedAt,
          },
          'files': <Object>[],
        };

    final stale = continueWatchingSummary(
        a.id,
        card('half-watched', 'MOVIE',
            activity: '2026-10-02T20:46:44Z',
            watchedAt: '2026-10-02T20:46:44Z',
            position: 672))!;
    final binge = continueWatchingSummary(
        a.id, card('next-up', 'EPISODE', activity: '2026-10-17T12:38:36Z'))!;

    // The server's order, which the merge must not undo.
    final rows = buildHomeRows([
      feeds(a, resuming: [binge, stale])
    ]);
    expect(rows.continueWatching.map((i) => i.ref.externalId),
        ['next-up', 'half-watched']);
  });

  test('copies on two servers are one card with a count', () {
    const ids = ExternalIds(tmdb: '7');
    final rows = buildHomeRows([
      feeds(a, favs: [item(a, 'a1', ids: ids)]),
      feeds(b, favs: [item(b, 'b1', ids: ids)]),
    ]);
    expect(rows.favorites, hasLength(1));
    expect(rows.extraCopies[rows.favorites.single.ref], 1);
  });
}
