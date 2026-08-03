import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/cast_device.dart';

const _device = CastDevice(
  id: 'd1',
  name: 'Living Room',
  protocol: CastProtocolKind.chromecast,
);

void main() {
  group('CastSession.connectionState', () {
    test('defaults to connected so existing call sites keep their meaning', () {
      const session = CastSession(
        device: _device,
        playbackState: CastPlaybackState.buffering,
      );

      expect(session.connectionState, CastConnectionState.connected);
      expect(session.isStale, isFalse);
    });

    test('isStale is true only when the connection is lost', () {
      const connecting = CastSession(
        device: _device,
        playbackState: CastPlaybackState.idle,
        connectionState: CastConnectionState.connecting,
      );
      const lost = CastSession(
        device: _device,
        playbackState: CastPlaybackState.idle,
        connectionState: CastConnectionState.lost,
      );

      expect(connecting.isStale, isFalse);
      expect(lost.isStale, isTrue);
    });

    test('a connected session can carry no media at all', () {
      const idle = CastSession(
        device: _device,
        playbackState: CastPlaybackState.idle,
        connectionState: CastConnectionState.connected,
      );

      expect(idle.mediaInfo, isNull);
      expect(idle.isStale, isFalse);
    });

    test('copyWith carries connectionState through', () {
      const session = CastSession(
        device: _device,
        playbackState: CastPlaybackState.playing,
      );

      final lost = session.copyWith(
        connectionState: CastConnectionState.lost,
      );

      expect(lost.isStale, isTrue);
      expect(lost.playbackState, CastPlaybackState.playing);
    });
  });
}
