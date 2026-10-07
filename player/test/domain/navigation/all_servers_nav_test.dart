import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/navigation/nav_destination.dart';
import 'package:player/domain/navigation/source_nav.dart';

void main() {
  test('maps merged rows to /all and hides the rest, in layout order', () {
    final entries = resolveAllServersNav(builtinDestinations);
    expect({
      for (final e in entries) e.id: e.route
    }, {
      'search': '/all/search',
      'home': '/all',
      'continue_watching': '/all/continue-watching',
      'movies': '/all/movies',
      'shows': '/all/shows',
      'recently_added': '/all/recently-added',
      'favorites': '/all/favorites',
      'collections': '/all/collections',
      'downloads': '/downloads',
      'settings': '/settings',
    });
    expect(entries.map((e) => e.id), [
      for (final d in builtinDestinations)
        if (!{'calendar', 'unwatched'}.contains(d.id)) d.id
    ]);
  });

  test('a reordered layout reorders the All servers rows too', () {
    final reversed = builtinDestinations.reversed.toList();
    final ids = resolveAllServersNav(reversed).map((e) => e.id).toList();
    expect(ids.indexOf('favorites'), lessThan(ids.indexOf('movies')));
  });

  test('Home matches only /all itself, so it never shadows another row', () {
    final entries = resolveAllServersNav(builtinDestinations);
    final home = entries.firstWhere((e) => e.id == 'home');
    expect(home.matches('/all'), isTrue);
    expect(home.matches('/all/favorites'), isFalse);
  });
}
