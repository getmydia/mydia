import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/mydia/mydia_client.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/core/sources/mydia/source_link.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/source_error.dart';

import '../../../presentation/screens/sources/fake_media_source.dart';
import '../../../test_utils/mydia_test_source.dart';
import 'fake_mydia_transport.dart';

const _p2pId = SourceId('p2p');
const _urlId = SourceId('url');
const _plexId = SourceId('plex');
const _missingId = SourceId('missing');
const _brokenId = SourceId('broken');

MydiaSource _mydia(MydiaCredentials creds, String accountId) =>
    testMydiaSourceOver(FakeMydiaTransport(),
        creds: creds, accountId: accountId);

ProviderContainer _container() {
  final broken = MydiaSource(
    source: testMydiaSource,
    client: MydiaClient(
      transport: FakeMydiaTransport(),
      load: () async => throw const SourceException.unreachable(),
      save: (_) async {},
      onUnauthorized: () {},
    ),
  );
  final container = ProviderContainer(overrides: [
    mediaSourceProvider(_p2pId).overrideWithValue(_mydia(
      const MydiaCredentials(
          instanceId: 'i', accessToken: 'a', nodeAddr: 'node-1'),
      'a1',
    )),
    mediaSourceProvider(_urlId).overrideWithValue(_mydia(
      const MydiaCredentials(
          instanceId: 'i', accessToken: 'a', serverUrl: 'http://box.test'),
      'a2',
    )),
    mediaSourceProvider(_plexId).overrideWithValue(FakeMediaSource()),
    mediaSourceProvider(_missingId).overrideWithValue(null),
    mediaSourceProvider(_brokenId).overrideWithValue(broken),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('sourceViaP2pProvider', () {
    test('is true only for a Mydia source paired over p2p', () async {
      final c = _container();
      expect(await c.read(sourceViaP2pProvider(_p2pId).future), isTrue);
      expect(await c.read(sourceViaP2pProvider(_urlId).future), isFalse);
      expect(await c.read(sourceViaP2pProvider(_plexId).future), isFalse);
    });

    test('is false for a missing source or unreadable credentials', () async {
      final c = _container();
      expect(await c.read(sourceViaP2pProvider(_missingId).future), isFalse);
      expect(await c.read(sourceViaP2pProvider(_brokenId).future), isFalse);
    });
  });

  group('sourceServerUrlProvider', () {
    test('is the direct URL, and null over p2p or for other sources', () async {
      final c = _container();
      expect(await c.read(sourceServerUrlProvider(_urlId).future),
          'http://box.test');
      expect(await c.read(sourceServerUrlProvider(_p2pId).future), isNull);
      expect(await c.read(sourceServerUrlProvider(_plexId).future), isNull);
      expect(await c.read(sourceServerUrlProvider(_missingId).future), isNull);
      expect(await c.read(sourceServerUrlProvider(_brokenId).future), isNull);
    });
  });
}
