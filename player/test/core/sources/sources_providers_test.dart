import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/core/sources/source_factories.dart';
import 'package:player/core/sources/plex/plex_media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';

class _FixedAuth extends AuthStateNotifier {
  _FixedAuth(this._value);
  final AsyncValue<AuthStatus> _value;
  @override
  AsyncValue<AuthStatus> build() => _value;
}

class _SettableAuth extends AuthStateNotifier {
  _SettableAuth(this._initial);
  final AsyncValue<AuthStatus> _initial;
  @override
  AsyncValue<AuthStatus> build() => _initial;
  void set(AsyncValue<AuthStatus> value) => state = value;
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
    test('builds home Mydia as a browsable Mydia source', () {
      final c = _container(const AsyncData(AuthStatus.authenticated));
      final source = c.read(mediaSourceProvider(SourceId.legacyMydia));
      expect(source, isA<MydiaSource>());
      expect(source!.id, SourceId.legacyMydia);
      expect(source.kind, SourceKind.mydia);
      expect(source.connection, SourceConnectionStatus.remote);
      expect(source.capabilities, contains(SourceCapability.searchable));
      expect(source.as<Searchable>(), isNotNull);
      expect(source.as<Downloadable>(), isNotNull);
    });

    test('home status follows auth without rebuilding the source', () {
      final auth = _SettableAuth(const AsyncData(AuthStatus.authenticated));
      final c = ProviderContainer(overrides: [
        authStateProvider.overrideWith(() => auth),
        thirdPartySourcesProvider.overrideWithValue(const []),
      ]);
      addTearDown(c.dispose);
      c.listen(mediaSourceProvider(SourceId.legacyMydia), (_, __) {});
      final home = c.read(mediaSourceProvider(SourceId.legacyMydia))!;
      final seen = <SourceConnectionStatus>[];
      home.statusListenable
          .addListener(() => seen.add(home.statusListenable.value));

      auth.set(const AsyncLoading<AuthStatus>());
      auth.set(const AsyncData(AuthStatus.offlineMode));
      auth.set(const AsyncData(AuthStatus.authenticated));

      expect(seen, [
        SourceConnectionStatus.connecting,
        SourceConnectionStatus.unreachable,
        SourceConnectionStatus.remote,
      ]);
      expect(c.read(mediaSourceProvider(SourceId.legacyMydia)), same(home));
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

  group('homeMydiaStatus', () {
    test('maps auth state to a connection status', () {
      expect(homeMydiaStatus(const AsyncLoading<AuthStatus>()),
          SourceConnectionStatus.connecting);
      expect(homeMydiaStatus(const AsyncData(AuthStatus.authenticated)),
          SourceConnectionStatus.remote);
      expect(homeMydiaStatus(const AsyncData(AuthStatus.offlineMode)),
          SourceConnectionStatus.unreachable);
      expect(
          homeMydiaStatus(
              AsyncError<AuthStatus>(Exception('x'), StackTrace.empty)),
          SourceConnectionStatus.unreachable);
    });
  });

  group('sourceRootRedirect', () {
    test('sends the legacy Mydia source to the existing home', () {
      expect(sourceRootRedirect('mydia', [Source.legacyMydia()]), '/');
    });

    test('leaves a guest Mydia on its own screen', () {
      const guestId = 'mguest:owner:inst-2';
      const guest = Source(
        account: ProviderAccount(
          id: 'mguest',
          kind: SourceKind.mydia,
          displayName: 'Lakeside',
          storageNamespace: 'source/mguest',
          activeProfileId: 'owner',
        ),
        profile: SourceProfile(
            id: 'owner', accountId: 'mguest', name: 'Owner', isOwner: true),
        server: SourceServer(
            id: 'inst-2',
            accountId: 'mguest',
            profileId: 'owner',
            name: 'Lakeside'),
      );
      expect(guest.id.value, guestId);
      expect(
          sourceRootRedirect(guestId, [Source.legacyMydia(), guest]), isNull);
      expect(sourceRootRedirect('mydia', [Source.legacyMydia(), guest]), '/');
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
