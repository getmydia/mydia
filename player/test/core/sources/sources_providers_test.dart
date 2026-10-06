import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/core/sources/plex/plex_media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';

import '../../test_utils/mydia_test_source.dart';

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

ProviderContainer _container({List<Source> sources = const []}) {
  final container = ProviderContainer(
    overrides: [
      thirdPartySourcesProvider.overrideWithValue(sources),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('sourcesProvider', () {
    test('lists the stored accounts', () {
      final c = _container(sources: [testMydiaSource, _plexSource]);
      expect(c.read(sourcesProvider), [testMydiaSource, _plexSource]);
    });

    test('is empty with no account', () {
      expect(_container().read(sourcesProvider), isEmpty);
    });
  });

  group('switchableSourcesProvider', () {
    test('is empty with a single source, which hides the switcher', () {
      final c = _container(sources: [testMydiaSource]);
      expect(c.read(switchableSourcesProvider), isEmpty);
    });

    test('lists every source once there are two', () {
      final c = _container(sources: [testMydiaSource, _plexSource]);
      expect(
        c.read(switchableSourcesProvider),
        [testMydiaSource, _plexSource],
      );
    });
  });

  group('activeSourceIdProvider', () {
    test('defaults to the first source', () {
      final c = _container(sources: [testMydiaSource, _plexSource]);
      expect(c.read(activeSourceIdProvider), testMydiaSourceId);
    });

    test('follows a selection that exists', () {
      final c = _container(sources: [testMydiaSource, _plexSource]);
      c.read(selectedSourceIdProvider.notifier).select(_plexSource.id);
      expect(c.read(activeSourceIdProvider), _plexSource.id);
    });

    test('falls back to the first source when the selection is gone', () {
      final c = _container(sources: [testMydiaSource]);
      c
          .read(selectedSourceIdProvider.notifier)
          .select(const SourceId('missing'));
      expect(c.read(activeSourceIdProvider), testMydiaSourceId);
    });

    test('is null with no sources', () {
      expect(_container().read(activeSourceIdProvider), isNull);
    });
  });

  group('mediaSourceProvider', () {
    test('builds a Mydia account as a browsable Mydia source', () {
      final c = _container(sources: [testMydiaSource]);
      final source = c.read(mediaSourceProvider(testMydiaSourceId));
      expect(source, isA<MydiaSource>());
      expect(source!.id, testMydiaSourceId);
      expect(source.kind, SourceKind.mydia);
      expect(source.capabilities, contains(SourceCapability.searchable));
      expect(source.as<Searchable>(), isNotNull);
      expect(source.as<Downloadable>(), isNotNull);
    });

    test('is null for an unknown id', () {
      final c = _container(sources: [testMydiaSource]);
      expect(c.read(mediaSourceProvider(const SourceId('nope'))), isNull);
    });

    test('is a live Plex source for a Plex source', () {
      final c = _container(sources: [_plexSource]);
      expect(
          c.read(mediaSourceProvider(_plexSource.id)), isA<PlexMediaSource>());
    });
  });

  group('sourceRootRedirect', () {
    test('sends the bound instance to the existing home', () {
      expect(
          sourceRootRedirect(testMydiaSourceId.value, [testMydiaSource],
              bound: testMydiaSourceId),
          '/');
    });

    test('leaves a Mydia that is not bound on its own screen', () {
      expect(sourceRootRedirect(testMydiaSourceId.value, [testMydiaSource]),
          isNull);
    });

    test('sends an unknown source home', () {
      expect(sourceRootRedirect('nope', [testMydiaSource]), '/');
    });

    test('leaves a third-party source on its own screen', () {
      expect(
        sourceRootRedirect(
          _plexSource.id.value,
          [testMydiaSource, _plexSource],
          bound: testMydiaSourceId,
        ),
        isNull,
      );
    });
  });
}
