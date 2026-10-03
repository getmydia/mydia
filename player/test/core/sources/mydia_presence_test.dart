import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';

class _MutableAuth extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.authenticated);

  void set(AsyncValue<AuthStatus> value) => state = value;
}

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(overrides: [
      authStateProvider.overrideWith(_MutableAuth.new),
      thirdPartySourcesProvider.overrideWithValue(const []),
    ]);
    addTearDown(container.dispose);
  });

  _MutableAuth auth() =>
      container.read(authStateProvider.notifier) as _MutableAuth;

  test('keeps Mydia listed while a retry passes through loading', () {
    container.listen(sourcesProvider, (_, __) {});
    expect(container.read(sourcesProvider), [Source.legacyMydia()]);

    auth().set(const AsyncLoading());
    expect(container.read(sourcesProvider), [Source.legacyMydia()],
        reason: 'retryConnection sets a bare loading state; the source '
            'must not blink out of the switcher');

    auth().set(const AsyncData(AuthStatus.unauthenticated));
    expect(container.read(sourcesProvider), isEmpty);
  });

  test('drops Mydia on an error', () {
    container.listen(sourcesProvider, (_, __) {});
    auth().set(AsyncError(Exception('down'), StackTrace.empty));
    expect(container.read(sourcesProvider), isEmpty);
  });
}
