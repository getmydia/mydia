import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/mydia_source.dart';
import 'package:player/core/sources/plex/plex_media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';

class _FixedAuth extends AuthStateNotifier {
  _FixedAuth(this._value);
  final AsyncValue<AuthStatus> _value;
  @override
  AsyncValue<AuthStatus> build() => _value;
}

const _plexSource = Source(
  account: ProviderAccount(
    id: 'acc1',
    kind: SourceKind.plex,
    displayName: 'someone@example.test',
    storageNamespace: 'source/acc1',
    activeProfileId: 'owner',
  ),
  profile: SourceProfile(
    id: 'owner',
    accountId: 'acc1',
    name: 'Owner',
    isOwner: true,
  ),
  server: SourceServer(
    id: 'srv9',
    accountId: 'acc1',
    profileId: 'owner',
    name: 'Basement',
  ),
);

ProviderContainer _container(
  AsyncValue<AuthStatus> auth, {
  List<Source> thirdParty = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      authStateProvider.overrideWith(() => _FixedAuth(auth)),
      thirdPartySourcesProvider.overrideWithValue(thirdParty),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('sourcesProvider', () {
    test('lists the legacy Mydia source when authenticated', () {
      final c = _container(const AsyncData(AuthStatus.authenticated));
      expect(c.read(sourcesProvider), [Source.legacyMydia()]);
    });

    test('keeps Mydia in offline mode, where credentials still exist', () {
      final c = _container(const AsyncData(AuthStatus.offlineMode));
      expect(c.read(sourcesProvider), [Source.legacyMydia()]);
    });

    test('omits Mydia when unauthenticated or still loading', () {
      expect(
        _container(const AsyncData(AuthStatus.unauthenticated))
            .read(sourcesProvider),
        isEmpty,
      );
      expect(
        _container(const AsyncLoading<AuthStatus>()).read(sourcesProvider),
        isEmpty,
      );
    });

    test('appends third-party sources after Mydia', () {
      final c = _container(
        const AsyncData(AuthStatus.authenticated),
        thirdParty: [_plexSource],
      );
      expect(c.read(sourcesProvider), [Source.legacyMydia(), _plexSource]);
    });
  });

  group('switchableSourcesProvider', () {
    test('is empty with a single source, which hides the switcher', () {
      final c = _container(const AsyncData(AuthStatus.authenticated));
      expect(c.read(switchableSourcesProvider), isEmpty);
    });

    test('lists every source once there are two', () {
      final c = _container(
        const AsyncData(AuthStatus.authenticated),
        thirdParty: [_plexSource],
      );
      expect(
        c.read(switchableSourcesProvider),
        [Source.legacyMydia(), _plexSource],
      );
    });
  });

  group('activeSourceIdProvider', () {
    test('defaults to the first source', () {
      final c = _container(
        const AsyncData(AuthStatus.authenticated),
        thirdParty: [_plexSource],
      );
      expect(c.read(activeSourceIdProvider), SourceId.legacyMydia);
    });

    test('follows a selection that exists', () {
      final c = _container(
        const AsyncData(AuthStatus.authenticated),
        thirdParty: [_plexSource],
      );
      c.read(selectedSourceIdProvider.notifier).select(_plexSource.id);
      expect(c.read(activeSourceIdProvider), _plexSource.id);
    });

    test('falls back to the first source when the selection is gone', () {
      final c = _container(const AsyncData(AuthStatus.authenticated));
      c
          .read(selectedSourceIdProvider.notifier)
          .select(const SourceId('missing'));
      expect(c.read(activeSourceIdProvider), SourceId.legacyMydia);
    });

    test('is null with no sources', () {
      final c = _container(const AsyncData(AuthStatus.unauthenticated));
      expect(c.read(activeSourceIdProvider), isNull);
    });
  });

  group('mediaSourceProvider', () {
    test('builds a MydiaSource for the legacy id', () {
      final c = _container(const AsyncData(AuthStatus.authenticated));
      final source = c.read(mediaSourceProvider(SourceId.legacyMydia));
      expect(source, isA<MydiaSource>());
      expect(source!.kind, SourceKind.mydia);
      expect(source.connection, SourceConnectionStatus.remote);
      expect(source.capabilities, isEmpty);
      expect(source.as<Object>(), isNull);
    });

    test('is null for an unknown id', () {
      final c = _container(const AsyncData(AuthStatus.authenticated));
      expect(c.read(mediaSourceProvider(const SourceId('nope'))), isNull);
    });

    test('is a live Plex source for a Plex source', () {
      final c = _container(
        const AsyncData(AuthStatus.authenticated),
        thirdParty: [_plexSource],
      );
      expect(
          c.read(mediaSourceProvider(_plexSource.id)), isA<PlexMediaSource>());
    });
  });

  group('MydiaSource.connection', () {
    SourceConnectionStatus status(AsyncValue<AuthStatus> auth) =>
        MydiaSource(source: Source.legacyMydia(), auth: auth).connection;

    test('maps auth state to a connection status', () {
      expect(status(const AsyncLoading<AuthStatus>()),
          SourceConnectionStatus.connecting);
      expect(status(const AsyncData(AuthStatus.authenticated)),
          SourceConnectionStatus.remote);
      expect(status(const AsyncData(AuthStatus.offlineMode)),
          SourceConnectionStatus.unreachable);
      expect(status(AsyncError<AuthStatus>(Exception('x'), StackTrace.empty)),
          SourceConnectionStatus.unreachable);
    });
  });

  group('sourceRootRedirect', () {
    test('sends the legacy Mydia source to the existing home', () {
      expect(sourceRootRedirect('mydia', [Source.legacyMydia()]), '/');
    });

    test('sends an unknown source home', () {
      expect(sourceRootRedirect('nope', [Source.legacyMydia()]), '/');
    });

    test('leaves a third-party source on its own screen', () {
      expect(
        sourceRootRedirect(
          _plexSource.id.value,
          [Source.legacyMydia(), _plexSource],
        ),
        isNull,
      );
    });
  });
}
