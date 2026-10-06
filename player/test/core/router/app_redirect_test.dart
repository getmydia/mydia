import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/router/app_router.dart';
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

  const bound = SourceId('macct:owner:inst-1');

  String? go(String location, {SourceId? boundId}) => appRedirect(
        location: location,
        sourcesLoading: false,
        thirdParty: const [],
        boundId: boundId,
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
          thirdParty: const [],
        ),
        isNull);
  });

  test('one Mydia: home stays home', () {
    expect(go('/', boundId: bound), isNull);
    expect(go('/movies', boundId: bound), isNull);
  });

  test('removing one of two Mydia: still bound, no redirect', () {
    // The binding falls to the remaining instance; the router only sees that
    // one is still bound.
    expect(go('/', boundId: const SourceId('mother:owner:inst-2')), isNull);
  });

  group('with Plex or Stash and no Mydia', () {
    String? go(String location, {bool loading = false}) => appRedirect(
          location: location,
          sourcesLoading: loading,
          thirdParty: const [fakeSource],
        );

    test('lands on the source instead of add-a-server', () {
      expect(go('/'), '/s/acc1:owner:aa11');
      expect(go('/movies'), '/s/acc1:owner:aa11');
    });

    test('lands on the remembered source, not always the first', () {
      const second = Source(
        account: ProviderAccount(
          id: 'acc2',
          kind: SourceKind.stash,
          displayName: 'stash',
          storageNamespace: 'source/acc2',
          activeProfileId: 'owner',
        ),
        profile: SourceProfile(
            id: 'owner', accountId: 'acc2', name: 'Owner', isOwner: true),
        server: SourceServer(
            id: 'main', accountId: 'acc2', profileId: 'owner', name: 'Den'),
      );
      String? landing(SourceId? active) => appRedirect(
            location: '/',
            sourcesLoading: false,
            thirdParty: const [fakeSource, second],
            activeId: active,
          );
      expect(landing(second.id), '/s/acc2:owner:main');
      expect(landing(const SourceId('gone:owner:x')), '/s/acc1:owner:aa11');
      expect(landing(null), '/s/acc1:owner:aa11');
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

    String? goGated(String location,
            {List<Source> thirdParty = const [], SourceId? boundId}) =>
        appRedirect(
          boundId: boundId,
          location: location,
          fullLocation: location,
          sourcesLoading: false,
          thirdParty: thirdParty,
          gated: gated,
        );

    test('a gated source route goes to unlock with the whole location', () {
      expect(
        appRedirect(
          boundId: bound,
          location: '/s/acc1:owner:srv9/player/42',
          fullLocation: '/s/acc1:owner:srv9/player/42?fileId=7',
          sourcesLoading: false,
          thirdParty: const [],
          gated: gated,
        ),
        unlockLocation('/s/acc1:owner:srv9/player/42?fileId=7'),
      );
    });

    test('a percent-encoded source id is still gated', () {
      const location = '/s/acc1%3Aowner%3Asrv9/item/movie/1';
      expect(
        appRedirect(
          boundId: bound,
          location: location,
          fullLocation: location,
          sourcesLoading: false,
          thirdParty: const [],
          gated: gated,
        ),
        unlockLocation(location),
      );
    });

    test('other sources and Mydia routes are untouched', () {
      expect(goGated('/s/acc2:owner:x', boundId: bound), isNull);
      expect(goGated('/movies', boundId: bound), isNull);
    });

    test('unlock is reachable with no Mydia server', () {
      expect(goGated('/unlock'), isNull);
    });

    test('with no Mydia, the landing skips a gated source', () {
      final locked = sourceOf('acc1', 'srv9');
      final open = sourceOf('acc2', 'srv1');
      expect(goGated('/', thirdParty: [locked, open]), '/s/acc2:owner:srv1');
      expect(goGated('/', thirdParty: [locked]),
          unlockLocation('/s/acc1:owner:srv9'));
    });

    test('Manage servers is reachable with no Mydia and every server hidden',
        () {
      expect(goGated('/sources/manage'), isNull);
    });
  });
}
