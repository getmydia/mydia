import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/domain/navigation/sidebar_layout.dart';
import 'package:player/domain/navigation/source_nav.dart';
import 'package:player/domain/sources/library.dart';

const _m = SourceId('ma:owner:aa');
const _p = SourceId('plex1:owner:pp');

final _layout = SidebarLayout.defaults.reconcile(downloadSupported: true);

Library _lib(SourceId s, String id, LibraryKind k, String title) => Library(
      ref: LibraryRef(sourceId: s, id: id),
      title: title,
      kind: k,
    );

const _mydiaCaps = {
  SourceCapability.searchable,
  SourceCapability.continueWatching,
  SourceCapability.calendar,
  SourceCapability.recentlyAdded,
  SourceCapability.unwatchedListing,
  SourceCapability.favoritesListing,
  SourceCapability.collections,
  SourceCapability.savedFilters,
};

void main() {
  test('two Mydia instances get identical entries under their own ids', () {
    List<String> ids(SourceId s) => [
          for (final e in resolveSourceNav(
            layout: _layout,
            source: s,
            capabilities: _mydiaCaps,
            libraries: [
              _lib(s, 'movies', LibraryKind.movies, 'Movies'),
              _lib(s, 'shows', LibraryKind.shows, 'TV Shows'),
            ],
          ))
            e.id,
        ];
    expect(ids(_m), ids(const SourceId('mb:owner:bb')));
    expect(ids(_m), containsAll(['calendar', 'collections', 'favorites']));
  });

  test('Plex hides Calendar and Collections and opens its own Movies', () {
    final nav = resolveSourceNav(
      layout: _layout,
      source: _p,
      capabilities: {
        SourceCapability.searchable,
        SourceCapability.continueWatching,
      },
      libraries: [
        _lib(_p, '1', LibraryKind.movies, 'Films'),
        _lib(_p, '2', LibraryKind.shows, 'Series'),
        _lib(_p, '3', LibraryKind.videos, 'Home Videos'),
      ],
    );
    final ids = [for (final e in nav) e.id];
    expect(ids, isNot(contains('calendar')));
    expect(ids, isNot(contains('collections')));
    expect(nav.firstWhere((e) => e.id == 'movies').route,
        '/s/plex1:owner:pp/library/1');
    expect(ids.indexOf('library-3'), ids.indexOf('shows') + 1);
  });

  test('a source without a movies library has no Movies entry', () {
    final ids = [
      for (final e in resolveSourceNav(
        layout: _layout,
        source: _p,
        capabilities: const {},
        libraries: [_lib(_p, '3', LibraryKind.videos, 'Home Videos')],
      ))
        e.id,
    ];
    expect(ids, isNot(contains('movies')));
    expect(ids, isNot(contains('search')));
    expect(ids.indexOf('library-3') + 1, ids.indexOf('downloads'));
  });

  test('Home matches only its own route', () {
    final nav = resolveSourceNav(
      layout: _layout,
      source: _m,
      capabilities: _mydiaCaps,
      libraries: const [],
    );
    final home = nav.firstWhere((e) => e.id == 'home');
    expect(home.matches('/s/ma:owner:aa'), isTrue);
    expect(home.matches('/s/ma:owner:aa/calendar'), isFalse);
  });

  test('reads the source id out of a location', () {
    expect(sourceIdFromLocation('/s/acc1:owner:aa11/library/movies'),
        'acc1:owner:aa11');
    expect(sourceIdFromLocation('/s/acc1:owner:aa11'), 'acc1:owner:aa11');
    expect(sourceIdFromLocation('/movies'), isNull);
    expect(sourceIdFromLocation('/s/%E0%A4%A/library'), isNull);
  });
}
