import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/router/legacy_routes.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/presentation/screens/all_servers/all_servers_cards.dart'
    show allServersRedirect;

const _a = SourceId('ma:owner:aa');
const _b = SourceId('mb:owner:bb');
const _p = SourceId('plex1:owner:pp');

String? go(String l,
        {SourceId? legacy,
        List<SourceId> mydia = const [_a],
        SourceId? active = _a}) =>
    legacyLocation(Uri.parse(l), legacy: legacy, mydia: mydia, active: active);

void main() {
  test('old movie link lands on the migrated instance', () {
    expect(go('/movie/123', legacy: _a, mydia: [_a, _b]),
        '/s/ma:owner:aa/movie/123');
    expect(go('/show/7', legacy: _a), '/s/ma:owner:aa/show/7');
    expect(go('/episode/8', legacy: _a), '/s/ma:owner:aa/episode/8');
  });

  test('offline player link keeps fileId and gains kind', () {
    final moved = Uri.parse(
        go('/player/episode/55?fileId=offline&title=Low%20Tide', legacy: _a)!);
    expect(moved.path, '/s/ma:owner:aa/player/55');
    expect(moved.queryParameters,
        {'fileId': 'offline', 'title': 'Low Tide', 'kind': 'episode'});
  });

  test('ambiguous link goes to the source list', () {
    expect(go('/show/7', mydia: [_a, _b]), '/sources/manage');
    expect(go('/', mydia: [_a, _b], active: null), isNull);
  });

  test('a single Mydia instance is the target without a migration', () {
    expect(go('/collection/9', mydia: [_b]), '/s/mb:owner:bb/collection/9');
  });

  test('a migrated id whose account is gone is ignored', () {
    expect(go('/calendar', legacy: _a, mydia: [_b]), '/s/mb:owner:bb/calendar');
  });

  test('no Mydia instance sends legacy pages to the source list', () {
    expect(go('/movie/1', mydia: const []), '/sources/manage');
    expect(go('/settings/devices', mydia: const []), '/sources/manage');
  });

  test('root and search follow the active source, Plex included', () {
    expect(go('/', active: _p), '/s/plex1:owner:pp');
    expect(go('/search?q=fog', active: _p), '/s/plex1:owner:pp/search?q=fog');
    expect(go('/', active: null), isNull);
    expect(go('/search?q=fog', active: null), isNull);
  });

  test('source routes and the queue player are not legacy', () {
    expect(go('/s/ma:owner:aa/movie/1'), isNull);
    expect(go('/player/queue?items=a'), isNull);
    expect(go('/downloads'), isNull);
    expect(go('/settings'), isNull);
    expect(go('/sources/manage'), isNull);
  });

  test('every legacy listing moves under the target', () {
    for (final p in [
      'favorites',
      'unwatched',
      'recently-added',
      'continue-watching',
      'calendar',
      'collections'
    ]) {
      expect(go('/$p', legacy: _a), '/s/ma:owner:aa/$p');
    }
    expect(go('/movies', legacy: _a), '/s/ma:owner:aa/library/movies');
    expect(go('/shows', legacy: _a), '/s/ma:owner:aa/library/shows');
    expect(go('/filter/f1', legacy: _a), '/s/ma:owner:aa/filter/f1');
    expect(go('/settings/devices', legacy: _a), '/sources/manage/ma:owner:aa');
  });

  test('/ and /search open All servers when it is on', () {
    String? all(String l, {required bool on}) => legacyLocation(Uri.parse(l),
        legacy: null, mydia: const [], active: _a, allServers: on);
    expect(all('/', on: true), '/all');
    expect(all('/search?q=x', on: true), '/all/search?q=x');
    expect(all('/', on: false), '/s/ma:owner:aa');
    expect(all('/search?q=x', on: false), '/s/ma:owner:aa/search?q=x');
  });

  test('All servers on does not touch other legacy locations', () {
    expect(
        legacyLocation(Uri.parse('/movie/1'),
            legacy: _a, mydia: const [_a], active: _a, allServers: true),
        '/s/ma:owner:aa/movie/1');
  });

  test('/all with fewer than two servers does not loop back to /all', () {
    // The /all route sends it to '/', which resolves with allServers false.
    expect(allServersRedirect(0), '/');
    expect(
        legacyLocation(Uri.parse('/'),
            legacy: null, mydia: const [], active: _a, allServers: false),
        '/s/ma:owner:aa');
    expect(
        legacyLocation(Uri.parse('/'),
            legacy: null, mydia: const [], active: null, allServers: false),
        isNull);
  });
}
