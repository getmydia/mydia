import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:player/app.dart';
import 'package:player/core/remote/remote_control_settings.dart';
import 'package:player/native/lib.dart';

/// One response `handleControlRequest` sent back, with the id it answered.
class _SentResponse {
  const _SentResponse(this.requestId, this.response);

  final String requestId;
  final FlutterRemoteControlResponse response;
}

FlutterInboundControlRequest _request(
  String requestId, {
  FlutterRemoteControlRequest request =
      const FlutterRemoteControlRequest.play(),
}) =>
    FlutterInboundControlRequest(
      peer: 'peer-node-id',
      requestId: requestId,
      request: request,
    );

void main() {
  late Box<dynamic> box;
  late RemoteControlSettings settings;
  late List<_SentResponse> sent;
  late List<FlutterInboundControlRequest> handled;
  var boxCounter = 0;

  setUp(() async {
    // In-memory backend: no `Hive.init` path, no file, nothing to clean up.
    boxCounter += 1;
    box = await Hive.openBox<dynamic>(
      'control_request_handling_$boxCounter',
      bytes: Uint8List(0),
    );
    settings = RemoteControlSettings(box: box);
    sent = [];
    handled = [];
  });

  tearDown(() async {
    await box.close();
  });

  Future<void> run(FlutterInboundControlRequest request) =>
      handleControlRequest(
        request: request,
        controllableEnabled: settings.controllableEnabled,
        respond: (id, response) async => sent.add(_SentResponse(id, response)),
        handle: (r) async => handled.add(r),
      );

  group('handleControlRequest', () {
    test('an opted-in device hands the request to the receiver', () async {
      await run(_request('req-1'));

      expect(handled.map((r) => r.requestId), ['req-1']);
      // The receiver owns answering from here; answering twice would put two
      // responses on one request id.
      expect(sent, isEmpty);
    });

    test('an opted-out device refuses without reaching the receiver', () async {
      await settings.setControllable(false);

      await run(_request('req-2'));

      expect(handled, isEmpty,
          reason: 'the roster check inside the receiver is a different gate; '
              'an opted-out device must not run it at all');
      expect(sent, hasLength(1));
      expect(sent.single.response,
          isA<FlutterRemoteControlResponse_NotAuthorized>());
    });

    test('the refusal answers the id that asked', () async {
      // A response carrying the wrong id leaves the real caller hanging and
      // answers a request nobody made.
      await settings.setControllable(false);

      await run(_request('req-3'));

      expect(sent.single.requestId, 'req-3');
    });

    test('opting out mid-session refuses the very next request', () async {
      // The reason the check lives here rather than at subscription time: a
      // session that started opted-in keeps a live subscription, so without
      // this recheck the device would stay controllable until it restarted.
      await run(_request('before'));
      expect(handled.map((r) => r.requestId), ['before']);

      await settings.setControllable(false);
      await run(_request('after'));

      expect(handled.map((r) => r.requestId), ['before'],
          reason: 'the request after the opt-out must not reach the receiver');
      expect(sent.single.requestId, 'after');
      expect(sent.single.response,
          isA<FlutterRemoteControlResponse_NotAuthorized>());
    });

    test('opting back in mid-session is served again', () async {
      await settings.setControllable(false);
      await run(_request('refused'));

      await settings.setControllable(true);
      await run(_request('served'));

      expect(handled.map((r) => r.requestId), ['served']);
    });

    test('the gate does not depend on which command was sent', () async {
      // Hello and GetState read what this device is playing, so the opt-out
      // has to cover them too, not just the transport commands.
      await settings.setControllable(false);

      await run(_request('hello',
          request: const FlutterRemoteControlRequest.hello(
            controllerName: 'phone',
            protocolVersion: 1,
          )));
      await run(_request('get-state',
          request: const FlutterRemoteControlRequest.getState()));

      expect(handled, isEmpty);
      expect(sent.map((s) => s.requestId), ['hello', 'get-state']);
      expect(
        sent.every(
            (s) => s.response is FlutterRemoteControlResponse_NotAuthorized),
        isTrue,
      );
    });

    test('a throwing receiver does not escape into the stream listener',
        () async {
      // The caller is a `.listen` callback with no error path, so anything
      // escaping here becomes an unhandled async error and takes down the
      // zone rather than dropping one request.
      await expectLater(
        handleControlRequest(
          request: _request('boom'),
          controllableEnabled: settings.controllableEnabled,
          respond: (id, response) async =>
              sent.add(_SentResponse(id, response)),
          handle: (_) async => throw Exception('receiver blew up'),
        ),
        completes,
      );
    });

    test('a throwing settings read does not escape either', () async {
      await expectLater(
        handleControlRequest(
          request: _request('boom'),
          controllableEnabled: () async => throw Exception('hive is gone'),
          respond: (id, response) async =>
              sent.add(_SentResponse(id, response)),
          handle: (r) async => handled.add(r),
        ),
        completes,
      );
      // Failing closed matters more than failing loudly: a settings read that
      // throws must not fall through into serving the request.
      expect(handled, isEmpty);
    });

    test('a throwing respond does not escape', () async {
      await settings.setControllable(false);

      await expectLater(
        handleControlRequest(
          request: _request('boom'),
          controllableEnabled: settings.controllableEnabled,
          respond: (_, __) async => throw Exception('host is gone'),
          handle: (r) async => handled.add(r),
        ),
        completes,
      );
    });
  });
}
