import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/remote/remote_control_intent.dart';
import 'package:player/native/lib.dart';

void main() {
  group('RemoteControlIntent.fromRequest', () {
    test('maps a seek to a transport intent carrying the position', () {
      final intent = RemoteControlIntent.fromRequest(
        FlutterRemoteControlRequest.seek(positionMs: BigInt.from(754000)),
      );

      expect(intent, isA<TransportIntent>());
      final transport = intent! as TransportIntent;
      expect(transport.action, TransportAction.seek);
      expect(transport.position, const Duration(milliseconds: 754000));
    });

    test('maps play without a position', () {
      final play = RemoteControlIntent.fromRequest(
        const FlutterRemoteControlRequest_Play(),
      )! as TransportIntent;

      expect(play.action, TransportAction.play);
      expect(play.position, isNull);
    });

    test('maps load content to a content reference', () {
      final intent = RemoteControlIntent.fromRequest(
        FlutterRemoteControlRequest_LoadContent(
          FlutterLoadContentRequest(
            mediaItemId: 'item-1',
            episodeId: 'ep-3',
            positionMs: BigInt.from(60000),
            audioTrack: null,
            subtitleTrack: null,
            autoplay: true,
          ),
        ),
      );

      expect(intent, isA<LoadContentIntent>());
      final load = intent! as LoadContentIntent;
      expect(load.mediaItemId, 'item-1');
      expect(load.episodeId, 'ep-3');
      expect(load.startAt, const Duration(minutes: 1));
      expect(load.autoplay, isTrue);
    });

    test('maps a null track id to clearing the track', () {
      final intent = RemoteControlIntent.fromRequest(
        const FlutterRemoteControlRequest_SelectSubtitleTrack(id: null),
      )! as TrackSelectionIntent;

      expect(intent.kind, TrackKind.subtitle);
      expect(intent.trackId, isNull);
    });

    test('returns null for Hello and GetState, which are not playback actions',
        () {
      expect(
        RemoteControlIntent.fromRequest(
            const FlutterRemoteControlRequest_GetState()),
        isNull,
      );
      expect(
        RemoteControlIntent.fromRequest(
          const FlutterRemoteControlRequest_Hello(
            controllerName: 'iPhone',
            protocolVersion: 1,
          ),
        ),
        isNull,
      );
    });
  });
}
