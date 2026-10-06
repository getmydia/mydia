import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/p2p/media_route.dart';
import 'package:player/core/sources/mydia/mydia_client.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_source.dart';
import 'package:player/domain/models/download_plan.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/source_error.dart';

import 'fake_mydia_transport.dart';
import 'mydia_source_test.dart' show guest, sid;

const _movie = ItemRef(sourceId: sid, kind: ItemKind.movie, externalId: 'm-1');

const _http = MydiaCredentials(
  instanceId: 'inst-2',
  accessToken: 'secret-token',
  serverUrl: 'https://lake.example//',
);
const _p2p = MydiaCredentials(
  instanceId: 'inst-2',
  accessToken: 'secret-token',
  nodeAddr: '{"id":"abc"}',
);

void main() {
  late LocalProxyService proxy;

  setUp(() => proxy = LocalProxyService.forTesting());
  tearDown(() => proxy.shutdown());

  MydiaSource guestSource(MydiaCredentials creds) => MydiaSource(
        source: guest,
        client: MydiaClient(
          transport: FakeMydiaTransport(),
          load: () async => creds,
          save: (_) async {},
          onUnauthorized: () {},
        ),
        proxy: () => proxy,
      );

  Future<DirectFile> fileOf(MydiaSource source) async {
    final plan = await source.resolve(_movie, 'original') as TranscodeJob;
    return plan.file('job-7');
  }

  group('guest file resolution', () {
    test('HTTP uses the bearer header and keeps the token out of the URL',
        () async {
      final file = await fileOf(guestSource(_http));
      expect(file.url, 'https://lake.example/api/v1/download/job/job-7/file');
      expect(file.url, isNot(contains('secret-token')));
      expect(file.headers, {'Authorization': 'Bearer secret-token'});
      expect(file.extension, 'mp4');
    });

    test('HTTP without a server URL is unreachable', () async {
      const creds =
          MydiaCredentials(instanceId: 'inst-2', accessToken: 'secret-token');
      expect(
        fileOf(guestSource(creds)),
        throwsA(isA<SourceException>()
            .having((e) => e.kind, 'kind', SourceErrorKind.unreachable)),
      );
    });

    test('p2p goes through the guest proxy target with no header', () async {
      final file = await fileOf(guestSource(_p2p));
      expect(file.url,
          MediaRoutes.download(proxy.targetBaseUrl('mguest'), 'job-7'));
      expect(file.headers, isEmpty);
      expect(proxy.isRunning, isTrue);
    });
  });

  test('disposing releases the hold a p2p download took', () async {
    final source = guestSource(_p2p);
    await fileOf(source);
    expect(proxy.isRunning, isTrue);
    source.dispose();
    await pumpEventQueue();
    expect(proxy.isRunning, isFalse);
  });

  test('disposing a source that never downloaded leaves the proxy alone',
      () async {
    final source = guestSource(_p2p);
    final other = Object();
    await proxy.start(owner: other, targetPeer: 'peer');
    source.dispose();
    await pumpEventQueue();
    expect(proxy.isRunning, isTrue);
    await proxy.release(other);
  });
}
