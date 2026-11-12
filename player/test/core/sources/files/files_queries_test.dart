import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/files/files_ids.dart';
import 'package:player/core/sources/files/files_queries.dart';
import 'package:player/core/sources/files/index/file_library_index.dart';
import 'package:player/core/sources/files/media_names.dart';
import 'package:player/domain/sources/item.dart';

import 'files_fixture.dart';

ItemSummary _item(String title, {DateTime? added, String? date}) => ItemSummary(
      ref: ItemRef(
          sourceId: filesLocalSource.id,
          kind: ItemKind.movie,
          externalId: title),
      title: title,
      sortTitle: filesSortTitle(title),
      addedAt: added,
      airDate: date,
    );

void main() {
  test('sort_title_drops_a_leading_article', () {
    expect(filesSortTitle('The Harbor Lights'), 'Harbor Lights');
    expect(filesSortTitle('An Owl'), 'Owl');
    expect(filesSortTitle('Theory of Moss'), 'Theory of Moss');
    expect(filesSortTitle('The'), 'The');
  });

  test('pages_by_decimal_offset', () {
    final items = [
      for (final t in ['a', 'b', 'c']) _item(t)
    ];
    final first = filesPage(items, 2);
    expect(first.items.map((i) => i.title), ['a', 'b']);
    expect(first.nextCursor!.value, '2');
    final second = filesPage(items, 2, cursor: first.nextCursor);
    expect(second.items.map((i) => i.title), ['c']);
    expect(second.nextCursor, isNull);
    expect(second.total, 3);
  });

  test('sorts_by_title_added_and_released', () {
    final items = [
      _item('The Bee', added: DateTime(2024), date: '2001-01-01'),
      _item('Ant', added: DateTime(2025), date: '1999-01-01'),
      _item('Cat', added: DateTime(2023), date: '2010-01-01'),
    ];
    String titles(List<ItemSummary> l) => l.map((i) => i.title).join(',');
    expect(titles(sortFilesItems(items, 'title')), 'Ant,The Bee,Cat');
    expect(titles(sortFilesItems(items, 'added')), 'Ant,The Bee,Cat');
    expect(titles(sortFilesItems(items, 'released')), 'Cat,The Bee,Ant');
    expect(titles(sortFilesItems(items, 'released', descending: false)),
        'Ant,The Bee,Cat');
  });

  test('backend_paths_join_the_root', () {
    const root = LibraryRoot(
        id: 'r', path: '/media/', kind: FilesLibraryKind.movies, title: 'M');
    expect(filesBackendPath(root, 'a/b.srt'), '/media/a/b.srt');
    const win = LibraryRoot(
        id: 'r', path: r'D:\Films', kind: FilesLibraryKind.movies, title: 'M');
    expect(filesBackendPath(win, 'b.srt'), r'D:\Films\b.srt');
  });

  test('identity_key_matches_the_rust_parser', () {
    expect(filesIdentityKey("Marvin's Agents"), 'marvinsagents');
    expect(filesIdentityKey('Spider-Moss 2'), 'spidermoss2');
  });

  test('folder_ids_round_trip', () {
    expect(parseFolderId(folderId('r1')), (rootId: 'r1', dir: ''));
    expect(
        parseFolderId(folderId('r1', 'a/b c')), (rootId: 'r1', dir: 'a/b c'));
    expect(parseFolderId('101'), isNull);
  });

  test('catalog_groups_files_into_movies_shows_and_loose_files', () async {
    final f = await FilesFixture.create();
    final catalog = FilesCatalog.read(
      sourceId: f.sourceId,
      index: f.index,
      progress: f.progress,
      l10n: filesL10n,
    );
    expect(catalog.movies.keys.toSet(), {'101', '102'});
    expect(catalog.movies['101']!.files, hasLength(2));
    expect(catalog.shows['201']!.episodeKeys, [(1, 1), (1, 2), (1, 3), (0, 1)]);
    expect(catalog.unmatched.values.single.path, 'loose/home video.mkv');
    // A show is as new as its newest file; a movie as old as its oldest.
    expect(catalog.showSummary(catalog.shows['201']!).addedAt,
        filesT0.add(const Duration(days: 1)));
    expect(
        catalog.movieSummary(catalog.movies['101']!).externalIds.tmdb, '101');
  });
}
