import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/router/app_router.dart';
import 'package:player/core/router/legacy_routes.dart';
import 'package:player/core/sources/lock/source_lock_controller.dart';
import 'package:player/core/sources/source.dart';

import '../../domain/merged/fake_merged_source.dart';
import '../../presentation/screens/sources/fake_media_source.dart'
    show fakeSource;

void main() {
  test('/all* waits for saved sources before deciding', () {
    final two = [
      FakeMergedSource(fakeServer('a')),
      FakeMergedSource(fakeServer('b')),
    ];
    expect(allServersRouteRedirect(sourcesLoading: true, included: const []),
        isNull);
    expect(allServersRouteRedirect(sourcesLoading: false, included: const []),
        '/');
    expect(
        allServersRouteRedirect(sourcesLoading: false, included: two), isNull);
  });

  const mydiaId = SourceId('macct:owner:inst-1');

  String? go(String location) => appRedirect(
        location: location,
        sourcesLoading: false,
        sources: const [],
      );

  test('no sources at all: add a server', () {
    expect(go('/'), '/sources/add');
    expect(go('/movies'), '/sources/add');
  });

  test('no sources: the add routes, unlock, login and manage stay', () {
    for (final l in [
      '/sources/add',
      '/sources/add/mydia',
      '/sources/add/plex',
      '/unlock',
      '/sources/manage',
      '/login',
    ]) {
      expect(go(l), isNull, reason: l);
    }
  });

  test('sources still loading: no redirect', () {
    expect(
        appRedirect(
          location: '/',
          sourcesLoading: true,
          sources: const [],
        ),
        isNull);
  });

  group('legacy locations', () {
    String? legacy(Uri u) => legacyLocation(u,
        legacy: mydiaId, mydia: const [mydiaId], active: mydiaId);

    String? goLegacy(String location,
            {Set<SourceId> gated = const {},
            List<Source> sources = const []}) =>
        appRedirect(
          location: location,
          fullLocation: location,
          sourcesLoading: false,
          sources: sources,
          gated: gated,
          legacy: legacy,
        );

    test('an old Mydia page moves under its source', () {
      expect(goLegacy('/movie/1'), '/s/macct:owner:inst-1/movie/1');
    });

    test('a Mydia-only install lands on its source from /', () {
      expect(goLegacy('/'), '/s/macct:owner:inst-1');
    });

    test('a gated target moves first and is gated on the next pass', () {
      final gated = {mydiaId};
      expect(
          goLegacy('/movie/1', gated: gated), '/s/macct:owner:inst-1/movie/1');
      expect(
        goLegacy('/s/macct:owner:inst-1/movie/1', gated: gated),
        unlockLocation('/s/macct:owner:inst-1/movie/1'),
      );
    });

    test('nothing moves while the stored sources load', () {
      expect(
        appRedirect(
          location: '/movie/1',
          sourcesLoading: true,
          sources: const [],
          legacy: legacy,
        ),
        isNull,
      );
    });

    test('with no sources, / still goes to add-a-server', () {
      expect(
        appRedirect(
          location: '/',
          sourcesLoading: false,
          sources: const [],
          legacy: (u) =>
              legacyLocation(u, legacy: null, mydia: const [], active: null),
        ),
        '/sources/add',
      );
    });
  });

  group('with Plex or Stash and no Mydia', () {
    String? go(String location, {bool loading = false}) => appRedirect(
          location: location,
          sourcesLoading: loading,
          sources: const [fakeSource],
        );

    test('lands on the active source instead of add-a-server', () {
      String? landing(String l) => appRedirect(
            location: l,
            sourcesLoading: false,
            sources: const [fakeSource],
            legacy: (u) => legacyLocation(u,
                legacy: null, mydia: const [], active: fakeSource.id),
          );
      expect(landing('/'), '/s/acc1:owner:aa11');
      expect(landing('/search?q=x'), '/s/acc1:owner:aa11/search?q=x');
    });

    test('app pages that are not legacy stay put', () {
      expect(go('/downloads'), isNull);
      expect(go('/settings'), isNull);
      expect(go('/all'), isNull);
    });

    test('leaves source, management and login routes alone', () {
      expect(go('/s/acc1:owner:aa11'), isNull);
      expect(go('/s/acc1:owner:aa11/library/1'), isNull);
      expect(go('/sources/manage'), isNull);
      expect(go('/login'), isNull);
    });

    test('waits while the stored sources load', () {
      expect(go('/', loading: true), isNull);
    });
  });
  group('gated sources', () {
    final gated = {const SourceId('acc1:owner:srv9')};

    Source sourceOf(String account, String server) => Source(
          account: ProviderAccount(
            id: account,
            kind: SourceKind.plex,
            displayName: account,
            storageNamespace: 'source/$account',
            activeProfileId: 'owner',
          ),
          profile: SourceProfile(
              id: 'owner', accountId: account, name: 'Owner', isOwner: true),
          server: SourceServer(
              id: server, accountId: account, profileId: 'owner', name: server),
        );

    String? goGated(String location, {List<Source> sources = const []}) =>
        appRedirect(
          location: location,
          fullLocation: location,
          sourcesLoading: false,
          sources: sources,
          gated: gated,
        );

    test('a gated source route goes to unlock with the whole location', () {
      expect(
        appRedirect(
          location: '/s/acc1:owner:srv9/player/42',
          fullLocation: '/s/acc1:owner:srv9/player/42?fileId=7',
          sourcesLoading: false,
          sources: const [],
          gated: gated,
        ),
        unlockLocation('/s/acc1:owner:srv9/player/42?fileId=7'),
      );
    });

    test('a percent-encoded source id is still gated', () {
      const location = '/s/acc1%3Aowner%3Asrv9/item/movie/1';
      expect(
        appRedirect(
          location: location,
          fullLocation: location,
          sourcesLoading: false,
          sources: const [],
          gated: gated,
        ),
        unlockLocation(location),
      );
    });

    test('other source routes are untouched', () {
      expect(
          goGated('/s/acc2:owner:x', sources: [sourceOf('acc2', 'x')]), isNull);
    });

    test('unlock is reachable with no Mydia server', () {
      expect(goGated('/unlock'), isNull);
    });

    test('with only gated sources, a pass over the landing unlocks it', () {
      final locked = sourceOf('acc1', 'srv9');
      expect(goGated('/s/acc1:owner:srv9', sources: [locked]),
          unlockLocation('/s/acc1:owner:srv9'));
    });

    test('Manage servers is reachable with no Mydia and every server hidden',
        () {
      expect(goGated('/sources/manage'), isNull);
    });
  });
}
