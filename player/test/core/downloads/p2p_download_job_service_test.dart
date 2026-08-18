import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_job_service.dart';
import 'package:player/core/downloads/p2p_download_job_service.dart';
import 'package:player/core/p2p/local_proxy_service.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/domain/models/download_option.dart';

import '../p2p/proxy_fetch.dart';
import '../p2p/test_p2p_service.dart';

class GraphqlCall {
  final String peer;
  final String query;
  final Map<String, dynamic>? variables;
  final String? operationName;
  final String? authToken;

  const GraphqlCall({
    required this.peer,
    required this.query,
    required this.variables,
    required this.operationName,
    required this.authToken,
  });
}

class FakeP2pService extends P2pService {
  GraphqlCall? lastGraphqlCall;

  Future<Map<String, dynamic>> Function(GraphqlCall call)? onGraphql;

  @override
  Future<Map<String, dynamic>> sendGraphQLRequest({
    required String peer,
    required String query,
    Map<String, dynamic>? variables,
    String? operationName,
    String? authToken,
  }) async {
    final call = GraphqlCall(
      peer: peer,
      query: query,
      variables: variables,
      operationName: operationName,
      authToken: authToken,
    );

    lastGraphqlCall = call;

    final handler = onGraphql;
    if (handler == null) {
      throw Exception('GraphQL handler not configured');
    }

    return handler(call);
  }
}

class FakeLocalProxyService extends LocalProxyService {
  final int fakePort;

  FakeLocalProxyService({this.fakePort = 12345}) : super(FakeP2pService());

  @override
  int get port => fakePort;
}

void main() {
  group('P2pDownloadJobService', () {
    late FakeP2pService p2p;
    late FakeLocalProxyService localProxy;
    late P2pDownloadJobService service;

    const serverNodeAddr = 'server-node-addr';
    const authToken = 'auth-token';

    setUp(() {
      p2p = FakeP2pService();
      localProxy = FakeLocalProxyService();
      service = P2pDownloadJobService(
        p2pService: p2p,
        localProxy: localProxy,
        serverNodeAddr: serverNodeAddr,
        authToken: authToken,
      );
    });

    test('getOptions returns options and sends expected GraphQL request',
        () async {
      p2p.onGraphql = (_) async => {
            'downloadOptions': [
              {
                'resolution': '1080p',
                'label': 'Full HD',
                'estimatedSize': 5 * 1024 * 1024,
              },
              {
                'resolution': '720p',
                'label': 'HD',
                'estimatedSize': 2 * 1024 * 1024,
              },
            ],
          };

      final result = await service.getOptions('movie', 'movie-1');

      expect(result, isA<DownloadOptionsResponse>());
      expect(result.options, hasLength(2));
      expect(result.options.first.resolution, equals('1080p'));
      expect(result.options.first.label, equals('Full HD'));

      final call = p2p.lastGraphqlCall;
      expect(call, isNotNull);
      expect(call!.peer, equals(serverNodeAddr));
      expect(call.operationName, equals('DownloadOptions'));
      expect(call.authToken, equals(authToken));
      expect(call.variables, equals({'contentType': 'movie', 'id': 'movie-1'}));
      expect(call.query, contains('downloadOptions'));
    });

    test(
        'getOptions throws DownloadServiceException when response is missing options',
        () async {
      p2p.onGraphql = (_) async => {'downloadOptions': null};

      expect(
        () => service.getOptions('movie', 'movie-1'),
        throwsA(isA<DownloadServiceException>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', 'No options returned')),
      );
    });

    test('prepareDownload parses status and file size', () async {
      p2p.onGraphql = (_) async => {
            'prepareDownload': {
              'jobId': 'job-1',
              'status': 'transcoding',
              'progress': 0.25,
              'error': null,
              'fileSize': 12345,
            },
          };

      final result = await service.prepareDownload(
        contentType: 'movie',
        id: 'movie-1',
        resolution: '720p',
      );

      expect(result.jobId, equals('job-1'));
      expect(result.status, equals(DownloadJobStatusType.transcoding));
      expect(result.progress, equals(0.25));
      expect(result.currentFileSize, equals(12345));

      final call = p2p.lastGraphqlCall;
      expect(call, isNotNull);
      expect(call!.operationName, equals('PrepareDownload'));
      expect(
        call.variables,
        equals({'contentType': 'movie', 'id': 'movie-1', 'resolution': '720p'}),
      );
    });

    test('prepareDownload throws when response is missing prepareDownload',
        () async {
      p2p.onGraphql = (_) async => {'prepareDownload': null};

      expect(
        () => service.prepareDownload(
          contentType: 'movie',
          id: 'movie-1',
          resolution: '720p',
        ),
        throwsA(isA<DownloadServiceException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.message, 'message', 'Failed to prepare download')),
      );
    });

    test('getJobStatus returns job details', () async {
      p2p.onGraphql = (_) async => {
            'downloadJobStatus': {
              'jobId': 'job-123',
              'status': 'ready',
              'progress': 1.0,
              'error': null,
              'fileSize': 777,
            },
          };

      final result = await service.getJobStatus('job-123');

      expect(result.jobId, equals('job-123'));
      expect(result.status, equals(DownloadJobStatusType.ready));
      expect(result.progress, equals(1.0));
      expect(result.currentFileSize, equals(777));

      final call = p2p.lastGraphqlCall;
      expect(call, isNotNull);
      expect(call!.operationName, equals('DownloadJobStatus'));
      expect(call.variables, equals({'jobId': 'job-123'}));
    });

    test('getJobStatus throws 404 when job data is missing', () async {
      p2p.onGraphql = (_) async => {'downloadJobStatus': null};

      expect(
        () => service.getJobStatus('missing-job'),
        throwsA(isA<DownloadServiceException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.message, 'message', 'Job not found')),
      );
    });

    test('cancelJob succeeds when success is true', () async {
      p2p.onGraphql = (_) async => {
            'cancelDownloadJob': {'success': true},
          };

      await service.cancelJob('job-9');

      final call = p2p.lastGraphqlCall;
      expect(call, isNotNull);
      expect(call!.operationName, equals('CancelDownloadJob'));
      expect(call.variables, equals({'jobId': 'job-9'}));
    });

    test('cancelJob throws when success is false', () async {
      p2p.onGraphql = (_) async => {
            'cancelDownloadJob': {'success': false},
          };

      expect(
        () => service.cancelJob('job-9'),
        throwsA(isA<DownloadServiceException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.message, 'message', 'Failed to cancel job')),
      );
    });

    test('getDownloadUrl returns local proxy URL', () async {
      final url = await service.getDownloadUrl('job-42');
      expect(url, equals('http://127.0.0.1:12345/download/job-42/file'));
    });

    // Downloads and playback serve from one proxy, but each captured its own
    // peer and token — this service at construction, the player when it
    // initialised. A token refresh between the two leaves this one holding a
    // stale value, and `start` re-targets a proxy that is already running, so
    // asking for a download URL could point live playback at the wrong token
    // and get its range requests rejected.
    group('sharing the proxy with playback', () {
      late TestP2pService proxyPeer;
      late LocalProxyService sharedProxy;
      late Object playback;
      late P2pDownloadJobService downloads;

      setUp(() async {
        proxyPeer = TestP2pService();
        sharedProxy = LocalProxyService(proxyPeer);
        playback = Object();

        await sharedProxy.start(
          owner: playback,
          targetPeer: 'playback-peer',
          authToken: 'fresh-token',
        );
        addTearDown(sharedProxy.shutdown);

        downloads = P2pDownloadJobService(
          p2pService: p2p,
          localProxy: sharedProxy,
          serverNodeAddr: 'stale-peer',
          authToken: 'stale-token',
        );
      });

      test('a download leaves playback\'s peer and token alone', () async {
        await downloads.getDownloadUrl('job-42');

        proxyPeer.onSendHlsRequest = (_) async => testHlsResponse(
              status: 200,
              contentType: 'application/vnd.apple.mpegurl',
              data: const [],
            );
        await proxyGet(
          'http://127.0.0.1:${sharedProxy.port}/hls/sess-1/index.m3u8',
        );

        final call = proxyPeer.calls.single;
        expect(call.peer, 'playback-peer');
        expect(call.authToken, 'fresh-token');
      });

      test('a download still holds the proxy when playback lets go', () async {
        await downloads.getDownloadUrl('job-42');

        await sharedProxy.stop(playback);

        expect(sharedProxy.isRunning, isTrue,
            reason: 'the transfer is still pulling bytes through this proxy');
      });
    });
  });
}
