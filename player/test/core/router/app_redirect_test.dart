import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/router/app_router.dart';

void main() {
  String? go(AuthStatus status, String location) =>
      appRedirect(auth: AsyncData(status), location: location);

  test('keeps the Mydia rules', () {
    expect(appRedirect(auth: const AsyncLoading(), location: '/'), isNull);
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
}
