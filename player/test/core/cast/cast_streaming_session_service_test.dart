import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_backend.dart';
import 'package:player/core/cast/cast_streaming_session_service.dart';
import 'package:player/domain/sources/source_error.dart';

import '../../test_utils/scripted_mydia_transport.dart';
import '../sources/mydia/fake_mydia_client.dart';
import '../sources/mydia/fake_mydia_transport.dart';

Map<String, dynamic> _started({int? startPosition}) => {
      '__typename': 'RootMutationType',
      'startStreamingSession': {
        '__typename': 'StreamingSessionResult',
        'sessionId': 'sess-1',
        'duration': null,
        'startPosition': startPosition,
      },
    };

void main() {
  late FakeMydiaTransport server;
  late MydiaCastStreamingSessionService service;

  setUp(() {
    server = FakeMydiaTransport();
    service = MydiaCastStreamingSessionService(fakeMydiaClient(server));
  });

  test('starts a copy session and returns the offset the server used',
      () async {
    server.handlers['StartStreamingSession'] =
        (_) => _started(startPosition: 42);

    final started = await service.start(
      fileId: 'file-1',
      transcode: false,
      startPosition: const Duration(seconds: 40),
    );

    expect(started.sessionId, 'sess-1');
    expect(started.startOffset, const Duration(seconds: 42));
    expect(server.calls.single.vars['fileId'], 'file-1');
    expect(server.calls.single.vars['strategy'], 'HLS_COPY');
    expect(server.calls.single.vars['startPosition'], 40);
  });

  test('asks for a transcode when told to', () async {
    server.handlers['StartStreamingSession'] = (_) => _started();

    await service.start(fileId: 'file-1', transcode: true);

    expect(server.calls.single.vars['strategy'], 'TRANSCODE');
  });

  test('a refusal surfaces as a cast backend failure', () async {
    server.handlers['StartStreamingSession'] =
        (_) => throw const SourceException.server('no capacity');

    await expectLater(
      service.start(fileId: 'file-1', transcode: false),
      throwsA(isA<CastBackendException>()),
    );
  });

  test('an unreachable server surfaces as a cast backend failure', () async {
    server.unreachable = true;

    await expectLater(
      service.start(fileId: 'file-1', transcode: false),
      throwsA(isA<CastBackendException>()),
    );
  });

  test('an old server is downgraded once, then goes straight to legacy',
      () async {
    final scripted = ScriptedMydiaTransport((request, _) {
      if (request.operation == 'StartStreamingSession') {
        return graphqlError('Unknown argument "maxHeight" on field '
            '"startStreamingSession" of type "RootMutationType".');
      }
      return _started(startPosition: 7);
    });
    final old = MydiaCastStreamingSessionService(fakeMydiaClient(scripted));

    final first = await old.start(
      fileId: 'file-1',
      transcode: false,
      startPosition: const Duration(seconds: 5),
    );
    expect(first.sessionId, 'sess-1');
    expect(first.startOffset, const Duration(seconds: 7));
    expect(scripted.requests.map((r) => r.operation),
        ['StartStreamingSession', 'StartStreamingSessionLegacy']);
    final retry = scripted.requests.last.variables;
    expect(retry['fileId'], 'file-1');
    expect(retry['startPosition'], 5);
    expect(retry.containsKey('maxHeight'), isFalse);
    expect(retry.containsKey('playlistMode'), isFalse);

    await old.start(fileId: 'file-2', transcode: true);
    expect(scripted.requests, hasLength(3));
    expect(scripted.requests.last.operation, 'StartStreamingSessionLegacy');
  });

  test('ending a session never throws', () async {
    server.unreachable = true;

    await service.end('sess-1');

    expect(server.calls.single.operation, 'EndStreamingSession');
  });
}
