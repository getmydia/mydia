import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/router/app_router.dart';

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
