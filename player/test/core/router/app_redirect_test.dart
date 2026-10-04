import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/router/app_router.dart';
import 'package:player/core/sources/lock/source_lock_controller.dart';
import 'package:player/core/sources/source.dart';

import '../../presentation/screens/sources/fake_media_source.dart'
    show fakeSource;

void main() {
  String? go(AuthStatus status, String location) => appRedirect(
        auth: AsyncData(status),
        location: location,
        sourcesLoading: false,
        thirdParty: const [],
      );

  test('keeps the Mydia rules', () {
    expect(
        appRedirect(
          auth: const AsyncLoading(),
          location: '/',
          sourcesLoading: false,
          thirdParty: const [],
        ),
        isNull);
    expect(go(AuthStatus.unauthenticated, '/'), '/login');
    expect(go(AuthStatus.unauthenticated, '/login'), isNull);
    expect(go(AuthStatus.offlineMode, '/movies'), '/downloads');
    expect(go(AuthStatus.offlineMode, '/player/movie/1'), isNull);
    expect(go(AuthStatus.authenticated, '/login'), '/');
    expect(go(AuthStatus.authenticated, '/movies'), isNull);
  });

  test('the add-server flow is reachable from the login screen', () {
    expect(go(AuthStatus.unauthenticated, '/sources/add'), isNull);
    expect(go(AuthStatus.unauthenticated, '/sources/add/plex'), isNull);
  });

  group('with Plex or Stash and no Mydia', () {
    String? go(String location, {bool loading = false}) => appRedirect(
          auth: const AsyncData(AuthStatus.unauthenticated),
          location: location,
          sourcesLoading: loading,
          thirdParty: const [fakeSource],
        );

    test('lands on the source instead of the login screen', () {
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
            auth: const AsyncData(AuthStatus.unauthenticated),
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

    String? goGated(AuthStatus status, String location,
            {List<Source> thirdParty = const []}) =>
        appRedirect(
          auth: AsyncData(status),
          location: location,
          fullLocation: location,
          sourcesLoading: false,
          thirdParty: thirdParty,
          gated: gated,
        );

    test('a gated source route goes to unlock with the whole location', () {
      expect(
        appRedirect(
          auth: const AsyncData(AuthStatus.authenticated),
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
          auth: const AsyncData(AuthStatus.authenticated),
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
      expect(goGated(AuthStatus.authenticated, '/s/acc2:owner:x'), isNull);
      expect(goGated(AuthStatus.authenticated, '/movies'), isNull);
    });

    test('unlock is reachable signed out and offline', () {
      expect(goGated(AuthStatus.unauthenticated, '/unlock'), isNull);
      expect(goGated(AuthStatus.offlineMode, '/unlock'), isNull);
    });

    test('signed out, the landing skips a gated source', () {
      final locked = sourceOf('acc1', 'srv9');
      final open = sourceOf('acc2', 'srv1');
      expect(
          goGated(AuthStatus.unauthenticated, '/', thirdParty: [locked, open]),
          '/s/acc2:owner:srv1');
      expect(goGated(AuthStatus.unauthenticated, '/', thirdParty: [locked]),
          unlockLocation('/s/acc1:owner:srv9'));
    });

    test('Manage servers is reachable signed out with every server hidden', () {
      expect(goGated(AuthStatus.unauthenticated, '/sources/manage'),
          isNot('/login'));
    });
  });
}
