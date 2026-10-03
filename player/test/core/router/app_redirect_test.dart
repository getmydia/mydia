import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/router/app_router.dart';
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
}
