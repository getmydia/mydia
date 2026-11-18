import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/mpv_surface_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('mydia/mpv-surface');

  Future<VideoOutputStart> answer(Object? reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'awaitVideoOutput');
      expect(call.arguments, {'handle': 5});
      return reply;
    });
    return const MpvSurfaceChannel().awaitVideoOutput(5);
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('MpvSurfaceChannel.awaitVideoOutput', () {
    test('started', () async {
      expect(await answer({'started': true, 'failed': false}),
          VideoOutputStart.started);
    });

    test('failed when mpv rejected the video output', () async {
      expect(await answer({'started': false, 'failed': true}),
          VideoOutputStart.failed);
    });

    test('timed out when the output is neither up nor rejected', () async {
      expect(await answer({'started': false, 'failed': false}),
          VideoOutputStart.timedOut);
    });

    test('timed out on an empty reply', () async {
      expect(await answer(null), VideoOutputStart.timedOut);
    });
  });
}
